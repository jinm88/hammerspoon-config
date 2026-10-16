-- 手动切换系统 HTTP/HTTPS/SOCKS 代理（由命令面板 feat_command_palette 调用）。
--
-- 不再监听 Wi-Fi，也不做自动健康检查；代理只在用户从面板选择时切换。
--
-- 代理端点和 networksetup 指令封装在 root:wheel 的 Setuid helper 中；
-- 本模块只允许向 helper 传入硬编码的 "local"、"remote" 或 "off"，不拼接 shell 命令。
--
-- helper profile：
--   local  -> 127.0.0.1:7890
--   remote -> 192.168.31.101:7890

local log = hs.logger.new('proxy', 'info')

local NETWORKSETUP_PATH = '/usr/sbin/networksetup'
local HELPER_PATH = os.getenv('HOME') .. '/.hammerspoon/bin/setproxy'

local PROFILES = {
	['local'] = { host = '127.0.0.1', name = '本机代理' },
	['remote'] = { host = '192.168.31.101', name = '远程代理' },
	['off'] = { host = nil, name = '关闭代理' },
}
local PROXY_PORT = 7890

-- 当前本模块确认/设定的代理动作：'local' | 'remote' | 'off' | nil（未知）
local currentAction = nil

local function trim(value)
	if value == nil then
		return ''
	end
	return (value:gsub('^%s*(.-)%s*$', '%1'))
end

local function runProxyHelper(action)
	if hs.fs.attributes(HELPER_PATH) == nil then
		log.ef('代理 helper 不存在：%s', HELPER_PATH)
		return false, 'helper 不存在：' .. HELPER_PATH
	end

	local completed = false
	local succeeded = false
	local failureMessage = nil

	local task = hs.task.new(HELPER_PATH, function(exitCode, stdOut, stdErr)
		completed = true
		succeeded = exitCode == 0
		if not succeeded then
			failureMessage = trim(stdErr)
			if failureMessage == '' then
				failureMessage = trim(stdOut)
			end
			if failureMessage == '' then
				failureMessage = 'exit code ' .. tostring(exitCode)
			end
			log.ef('代理切换失败：%s', failureMessage)
		end
	end, { action })

	if task == nil or not task:start() then
		log.e('无法启动代理 helper')
		return false, '无法启动代理 helper'
	end

	task:waitUntilExit()
	return completed and succeeded, failureMessage
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

-- 读取 HTTP / HTTPS / SOCKS 三类代理当前状态。
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

	local host = PROFILES[action] and PROFILES[action].host
	return host ~= nil
		and state.web.enabled
		and state.secure.enabled
		and state.socks.enabled
		and state.web.server == host
		and state.secure.server == host
		and state.socks.server == host
		and state.web.port == PROXY_PORT
		and state.secure.port == PROXY_PORT
		and state.socks.port == PROXY_PORT
end

-- 供命令面板调用：手动切换系统代理。action 只能是 local/remote/off。
local function setProxy(action)
	local profile = PROFILES[action]
	if profile == nil then
		log.ef('不支持的代理动作：%s', tostring(action))
		return
	end

	readProxyState(function(state)
		if proxyStateMatches(state, action) then
			currentAction = action
			log.i('当前系统代理已是目标状态（' .. action .. '），无需修改')
			hs.alert.show('代理未变：' .. profile.name, { duration = 1 })
			return
		end

		log.i('准备修改系统代理：' .. action)
		local ok, failureMessage = runProxyHelper(action)
		if not ok then
			hs.alert.show('代理切换失败：' .. (failureMessage or '未知错误'), { duration = 3 })
			return
		end

		currentAction = action
		hs.notify.new({
			title = 'Hammerspoon',
			informativeText = '已切换为' .. profile.name,
		}):send()
	end)
end

-- 面板「查看代理状态」用：刷新后回调返回当前状态描述。
local function describe(state)
	if state.web == nil or state.secure == nil or state.socks == nil then
		return '代理状态未知'
	end

	if not state.web.enabled and not state.secure.enabled and not state.socks.enabled then
		return '系统代理：关闭'
	end

	return string.format('系统代理：%s:%d（HTTP/HTTPS/SOCKS）',
		state.web.server ~= '' and state.web.server or '(未设置主机)',
		state.web.port or 0)
end

local function refreshStatus(callback)
	readProxyState(function(state)
		-- 能匹配已知 profile 时同步 currentAction，方便面板直接展示。
		for action in pairs(PROFILES) do
			if proxyStateMatches(state, action) then
				currentAction = action
				break
			end
		end
		if callback then
			callback(describe(state), state)
		end
	end)
end

-- 模块加载时读取一次真实状态，避免面板显示与系统设置脱节。
refreshStatus()

return {
	-- 手动切换：setProxy('local' | 'remote' | 'off')
	setProxy = setProxy,
	-- 查询状态：refreshStatus(fn(description, state))
	refreshStatus = refreshStatus,
	-- 当前本模块确认的代理动作：'local' | 'remote' | 'off' | nil（未知）
	current = function()
		return currentAction
	end,
	profiles = PROFILES,
}
