-- 根据 Wi-Fi 自动切换系统 HTTP/HTTPS/SOCKS 代理。
--
-- 代理端点和 networksetup 指令封装在 root:wheel 的 Setuid helper 中；
-- 本模块只允许向 helper 传入硬编码的 "local"、"remote" 或 "off"，不拼接 shell 命令。
--
-- helper profile：
--   local  -> 127.0.0.1:7890
--   remote -> 192.168.31.201:7890

local log = hs.logger.new('autoProxy', 'info')

local NETWORKSETUP_PATH = '/usr/sbin/networksetup'
local HELPER_PATH = os.getenv('HOME') .. '/.hammerspoon/bin/setproxy'
local CURL_PATH = '/usr/bin/curl'
local REMOTE_PROXY_URL = 'http://192.168.31.201:7890'

local HEALTH_NORMAL_INTERVAL = 300
local HEALTH_FAST_INTERVAL = 10
local HEALTH_CONNECT_TIMEOUT = 2
local HEALTH_MAX_TIME = 5
local HEALTH_PROXY_FAULT_LIMIT = 2

-- 检测只确认代理服务是否活着，不判断代理内部规则、节点或上游配置。
-- 国内组和国外组都显式走 remote 代理：任意一组有 HTTP 响应，就说明代理仍在工作。
local DOMESTIC_URLS = {
	'https://www.baidu.com',
	'https://www.qq.com',
}

local FOREIGN_URLS = {
	'https://www.gstatic.com/generate_204',
	'https://cp.cloudflare.com/generate_204',
}

-- 在此维护 SSID 与代理 profile 的白名单；未列出的网络默认关闭系统代理。
local REMOTE_SSIDS = {
	['Xiaomi_A3D4_5G'] = true,
}

local LOCAL_SSIDS = {
	-- 例如：['某个使用本机代理的 Wi-Fi'] = true,
}

-- 当前由本模块确认的系统代理动作。
local currentAction = nil
local healthCheckInProgress = false
local proxyFaultCount = 0

auto_proxy_health_timer = nil

local function proxyProfileForSSID(ssid)
	if ssid ~= nil and REMOTE_SSIDS[ssid] then
		return 'remote', '远程代理'
	end
	if ssid ~= nil and LOCAL_SSIDS[ssid] then
		return 'local', '本机代理'
	end
	return 'off', '关闭代理'
end

local function expectedProxyHost(action)
	if action == 'local' then
		return '127.0.0.1'
	end
	if action == 'remote' then
		return '192.168.31.201'
	end
	return nil
end

local function trim(value)
	if value == nil then
		return ''
	end
	return (value:gsub('^%s*(.-)%s*$', '%1'))
end

local function runProxyHelper(action)
	if hs.fs.attributes(HELPER_PATH) == nil then
		log.ef('代理 helper 不存在：%s', HELPER_PATH)
		return false
	end

	local completed = false
	local succeeded = false

	local task = hs.task.new(HELPER_PATH, function(exitCode, stdOut, stdErr)
		completed = true
		succeeded = exitCode == 0
		if not succeeded then
			local message = trim(stdErr)
			if message == '' then
				message = trim(stdOut)
			end
			if message == '' then
				message = 'exit code ' .. tostring(exitCode)
			end
			log.ef('代理切换失败：%s', message)
		end
	end, { action })

	if task == nil or not task:start() then
		log.e('无法启动代理 helper')
		return false
	end

	task:waitUntilExit()
	return completed and succeeded
end

local checkProxyHealth

local function stopHealthCheck()
	if auto_proxy_health_timer ~= nil then
		auto_proxy_health_timer:stop()
		auto_proxy_health_timer = nil
	end
end

local function scheduleHealthCheck(delay)
	stopHealthCheck()
	auto_proxy_health_timer = hs.timer.doAfter(delay, function()
		auto_proxy_health_timer = nil
		checkProxyHealth()
	end)
end

local function parseProxyState(output)
	local enabled = output:match('Enabled:%s*(%a+)')
	local server = trim(output:match('Server:%s*([^\n]*)'))
	local port = tonumber(output:match('Port:%s*(%d+)'))

	return {
		enabled = enabled ~= nil and enabled:lower() == 'yes',
		server = server,
		port = port,
	}
end

local function readProxyState(callback)
	local state = {}
	local remaining = 3

	local checks = {
		{ key = 'web', args = { '-getwebproxy', 'Wi-Fi' } },
		{ key = 'secure', args = { '-getsecurewebproxy', 'Wi-Fi' } },
		{ key = 'socks', args = { '-getsocksfirewallproxy', 'Wi-Fi' } },
	}

	for _, check in ipairs(checks) do
		local task = hs.task.new(NETWORKSETUP_PATH, function(exitCode, stdOut, stdErr)
			if exitCode == 0 then
				state[check.key] = parseProxyState(stdOut)
			else
				log.ef('读取代理状态失败 %s：%s', check.key, trim(stdErr))
			end

			remaining = remaining - 1
			if remaining == 0 then
				callback(state)
			end
		end, check.args)

		if task == nil or not task:start() then
			log.ef('无法启动 networksetup：%s', table.concat(check.args, ' '))
			remaining = remaining - 1
			if remaining == 0 then
				callback(state)
			end
		end
	end
end

local function proxyStateMatches(state, action)
	if state.web == nil or state.secure == nil or state.socks == nil then
		return false
	end

	if action == 'off' then
		return not state.web.enabled
			and not state.secure.enabled
			and not state.socks.enabled
	end

	local host = expectedProxyHost(action)
	return host ~= nil
		and state.web.enabled
		and state.secure.enabled
		and state.socks.enabled
		and state.web.server == host
		and state.secure.server == host
		and state.socks.server == host
		and state.web.port == 7890
		and state.secure.port == 7890
		and state.socks.port == 7890
end

-- 使用 curl 显式走 remote 代理。只要收到 HTTP 状态码，就证明代理有响应。
local function curlProbe(url, resultCallback)
	local args = {
		'--proxy', REMOTE_PROXY_URL,
		'--connect-timeout', tostring(HEALTH_CONNECT_TIMEOUT),
		'--max-time', tostring(HEALTH_MAX_TIME),
		'--silent', '--show-error',
		'--output', '/dev/null',
		'--write-out', '%{http_code}',
		url,
	}

	local task = hs.task.new(CURL_PATH, function(_, stdOut, stdErr)
		local httpCode = tonumber(trim(stdOut))

		-- 407、502、503、504 等也说明代理进程有 HTTP 响应；
		-- 只有 000 / curl 失败才表示连接拒绝、超时或代理无响应。
		local ok = httpCode ~= nil and httpCode >= 100 and httpCode < 600
		local detail
		if ok then
			detail = 'HTTP ' .. tostring(httpCode)
		else
			detail = trim(stdErr)
			if detail == '' then
				detail = 'HTTP ' .. tostring(httpCode or '000')
			end
		end

		resultCallback(ok, detail)
	end, args)

	if task == nil or not task:start() then
		resultCallback(false, 'failed to start curl')
	end
end

local function checkUrlGroup(name, urls, groupCallback)
	local remaining = #urls
	local anySucceeded = false
	local results = {}

	for _, url in ipairs(urls) do
		curlProbe(url, function(ok, detail)
			if ok then
				anySucceeded = true
			end

			results[#results + 1] = url .. ' => ' .. detail
				.. (ok and ' [OK]' or ' [FAIL]')

			remaining = remaining - 1
			if remaining == 0 then
				groupCallback(anySucceeded, name .. ': ' .. table.concat(results, '; '))
			end
		end)
	end
end

local function finishHealthCheck(domesticOK, domesticDetail, foreignOK, foreignDetail)
	healthCheckInProgress = false

	-- 任一组通过代理得到响应，都说明代理活着；国内组可通时绝不关闭。
	if domesticOK or foreignOK then
		proxyFaultCount = 0
		log.i('remote 代理有响应；' .. domesticDetail .. '；' .. foreignDetail)
		scheduleHealthCheck(HEALTH_NORMAL_INTERVAL)
		return
	end

	proxyFaultCount = proxyFaultCount + 1
	log.wf('remote 代理整体无响应（%d/%d）；%s；%s',
		proxyFaultCount, HEALTH_PROXY_FAULT_LIMIT, domesticDetail, foreignDetail)

	if proxyFaultCount < HEALTH_PROXY_FAULT_LIMIT then
		scheduleHealthCheck(HEALTH_FAST_INTERVAL)
		return
	end

	proxyFaultCount = 0
	log.i('连续整体无响应，准备关闭系统代理')

	if runProxyHelper('off') then
		stopHealthCheck()
		currentAction = 'off'
		hs.notify.new({
			title = 'Hammerspoon',
			informativeText = '国内、国外检测均无响应，已自动关闭系统代理',
		}):send()
	else
		scheduleHealthCheck(HEALTH_FAST_INTERVAL)
	end
end

checkProxyHealth = function()
	local ssid = hs.wifi.currentNetwork()

	if currentAction ~= 'remote'
		or ssid == nil
		or not REMOTE_SSIDS[ssid] then
		proxyFaultCount = 0
		healthCheckInProgress = false
		stopHealthCheck()
		return
	end

	if healthCheckInProgress then
		return
	end

	healthCheckInProgress = true
	local domesticOK = false
	local foreignOK = false
	local domesticResult = ''
	local foreignResult = ''
	local remaining = 2

	checkUrlGroup('国内组', DOMESTIC_URLS, function(ok, detail)
		domesticOK = ok
		domesticResult = detail
		remaining = remaining - 1
		if remaining == 0 then
			finishHealthCheck(domesticOK, domesticResult, foreignOK, foreignResult)
		end
	end)

	checkUrlGroup('国外组', FOREIGN_URLS, function(ok, detail)
		foreignOK = ok
		foreignResult = detail
		remaining = remaining - 1
		if remaining == 0 then
			finishHealthCheck(domesticOK, domesticResult, foreignOK, foreignResult)
		end
	end)
end

local function updateProxy(ssid)
	local action, profileName = proxyProfileForSSID(ssid)

	readProxyState(function(state)
		if proxyStateMatches(state, action) then
			currentAction = action
			log.i('当前系统代理已是目标状态（' .. action .. '），无需修改')

			if action == 'remote' then
				scheduleHealthCheck(HEALTH_NORMAL_INTERVAL)
			else
				stopHealthCheck()
			end
			return
		end

		log.i('准备修改系统代理：' .. action)
		if not runProxyHelper(action) then
			return
		end

		currentAction = action
		proxyFaultCount = 0
		healthCheckInProgress = false

		local informativeText
		if ssid == nil then
			informativeText = 'Wi-Fi 已断开，系统代理已关闭'
		elseif action == 'off' then
			informativeText = '已离开 ' .. ssid .. '，系统代理已关闭'
		else
			informativeText = '已连接 ' .. ssid .. '，已切换为' .. profileName
		end

		hs.notify.new({
			title = 'Hammerspoon',
			informativeText = informativeText,
		}):send()

		if action == 'remote' then
			-- 正常状态下每 5 分钟检测一次；失败后自动切换为快速检测。
			scheduleHealthCheck(HEALTH_NORMAL_INTERVAL)
		else
			stopHealthCheck()
		end
	end)
end

local lastSSID = hs.wifi.currentNetwork()

auto_proxy_wifi_watcher = hs.wifi.watcher.new(function()
	local currentSSID = hs.wifi.currentNetwork()
	if currentSSID ~= lastSSID then
		lastSSID = currentSSID
		updateProxy(currentSSID)
	end
end)
auto_proxy_wifi_watcher:start()

-- 加载配置时立即与当前网络同步一次，避免 Hammerspoon 重启后状态不一致。
updateProxy(lastSSID)
