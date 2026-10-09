-- 根据 Wi-Fi 自动切换系统 HTTP/HTTPS/SOCKS 代理。
--
-- 代理端点和 networksetup 指令封装在 root:wheel 的 Setuid helper 中；
-- 本模块只允许向 helper 传入硬编码的 "local"、"remote" 或 "off"，不拼接 shell 命令。
--
-- helper profile：
--   local  -> 127.0.0.1:7890
--   remote -> 192.168.31.201:7890

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

-- 当前由本模块成功应用的代理动作；nil 表示本模块没有持有已开启的代理。
local currentAction = nil
local healthCheckInProgress = false
local proxyFaultCount = 0
local lastHealthStatus = nil

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

local function runProxyHelper(action)
	if hs.fs.attributes(HELPER_PATH) == nil then
		hs.notify.new({
			title = 'Hammerspoon',
			informativeText = '代理 helper 不存在：' .. HELPER_PATH,
		}):send()
		return false
	end

	local completed = false
	local succeeded = false

	local task = hs.task.new(HELPER_PATH, function(exitCode, stdOut, stdErr)
		completed = true
		succeeded = exitCode == 0
		if not succeeded then
			local message = stdErr
			if message == nil or message == '' then
				message = stdOut
			end
			if message == nil or message == '' then
				message = 'exit code ' .. tostring(exitCode)
			end
			hs.notify.new({
				title = 'Hammerspoon 代理切换失败',
				informativeText = message,
			}):send()
		end
	end, { action })

	if task == nil or not task:start() then
		hs.notify.new({
			title = 'Hammerspoon',
			informativeText = '无法启动代理 helper',
		}):send()
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

local function trim(value)
	if value == nil then
		return ''
	end
	return (value:gsub('^%s*(.-)%s*$', '%1'))
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
		resultCallback(ok, httpCode or trim(stdErr))
	end, args)

	if task == nil or not task:start() then
		resultCallback(false, 'failed to start curl')
	end
end

local function checkUrlGroup(urls, groupCallback)
	local remaining = #urls
	local anySucceeded = false

	for _, url in ipairs(urls) do
		curlProbe(url, function(ok)
			if ok then
				anySucceeded = true
			end

			remaining = remaining - 1
			if remaining == 0 then
				groupCallback(anySucceeded)
			end
		end)
	end
end

local function notifyHealthStatus(status, domesticOK, foreignOK)
	if status == lastHealthStatus then
		return
	end
	lastHealthStatus = status

	local text
	if status == 'healthy' then
		text = 'remote 代理有响应'
	elseif status == 'proxy_fault' then
		text = 'remote 代理无响应；将快速复查'
	else
		return
	end

	hs.notify.new({
		title = 'Hammerspoon 代理检测',
		informativeText = text .. '（国内=' .. tostring(domesticOK)
			.. '，国外=' .. tostring(foreignOK) .. '）',
	}):send()
end

local function finishHealthCheck(domesticOK, foreignOK)
	healthCheckInProgress = false

	-- 任一组通过代理得到响应，都说明代理活着；国内组可通时绝不关闭。
	if domesticOK or foreignOK then
		proxyFaultCount = 0
		notifyHealthStatus('healthy', domesticOK, foreignOK)
		scheduleHealthCheck(HEALTH_NORMAL_INTERVAL)
		return
	end

	proxyFaultCount = proxyFaultCount + 1
	notifyHealthStatus('proxy_fault', domesticOK, foreignOK)

	if proxyFaultCount >= HEALTH_PROXY_FAULT_LIMIT then
		proxyFaultCount = 0
		if runProxyHelper('off') then
			stopHealthCheck()
			currentAction = 'off'
			lastHealthStatus = 'disabled'
			hs.notify.new({
				title = 'Hammerspoon',
				informativeText = '国内、国外检测均无响应，已自动关闭系统代理',
			}):send()
		else
			scheduleHealthCheck(HEALTH_FAST_INTERVAL)
		end
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
	local remaining = 2

	checkUrlGroup(DOMESTIC_URLS, function(ok)
		domesticOK = ok
		remaining = remaining - 1
		if remaining == 0 then
			finishHealthCheck(domesticOK, foreignOK)
		end
	end)

	checkUrlGroup(FOREIGN_URLS, function(ok)
		foreignOK = ok
		remaining = remaining - 1
		if remaining == 0 then
			finishHealthCheck(domesticOK, foreignOK)
		end
	end)
end

local function updateProxy(ssid)
	local action, profileName = proxyProfileForSSID(ssid)
	local message
	if ssid == nil then
		message = 'Wi-Fi 已断开，系统代理已关闭'
	else
		message = 'Wi-Fi：' .. ssid .. '，' .. profileName
	end

	proxyFaultCount = 0
	healthCheckInProgress = false
	lastHealthStatus = nil

	if runProxyHelper(action) then
		currentAction = action
		hs.alert.show(message)

		if action == 'remote' then
			-- 正常状态下每 5 分钟检测一次；失败后自动切换为快速检测。
			scheduleHealthCheck(HEALTH_NORMAL_INTERVAL)
		else
			stopHealthCheck()
		end
	end
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
