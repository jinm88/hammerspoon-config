-- 手动切换系统 HTTP/HTTPS/SOCKS 代理（由命令面板 feat_command_palette 调用）。
--
-- 直接调用 /usr/sbin/networksetup，不再依赖 setuid helper。首次执行某个动作时
-- macOS 会弹一次管理员授权，之后该动作即被记住、可静默执行。代理端点与
-- networksetup 参数均为模块内硬编码，不拼接 shell 命令、不接受外部输入。
--
-- profile：
--   local  -> 127.0.0.1:7890
--   remote -> 192.168.31.101:7890

local log = hs.logger.new('proxy', 'info')

local NETWORKSETUP_PATH = '/usr/sbin/networksetup'
local NETWORK_SERVICE = 'Wi-Fi'

local PROFILES = {
	['local'] = { host = '127.0.0.1', name = '本机代理' },
	['remote'] = { host = '192.168.31.101', name = '远程代理' },
	['off'] = { host = nil, name = '关闭代理' },
}
local PROXY_PORT = 7890

-- 当前本模块确认/设定的代理动作：'local' | 'remote' | 'off' | nil（未知）
local currentAction = nil

local describe -- 前向声明：setProxy 的回读校验会用到

local function trim(value)
	if value == nil then
		return ''
	end
	return (value:gsub('^%s*(.-)%s*$', '%1'))
end

-- 按 profile 生成 networksetup 调用序列（硬编码参数，无 shell 拼接）。
local function proxyCommands(action)
	if action == 'off' then
		return {
			{ '-setwebproxystate', NETWORK_SERVICE, 'off' },
			{ '-setsecurewebproxystate', NETWORK_SERVICE, 'off' },
			{ '-setsocksfirewallproxystate', NETWORK_SERVICE, 'off' },
		}
	end
	local host = PROFILES[action].host
	local port = tostring(PROXY_PORT)
	return {
		{ '-setwebproxy', NETWORK_SERVICE, host, port },
		{ '-setsecurewebproxy', NETWORK_SERVICE, host, port },
		{ '-setsocksfirewallproxy', NETWORK_SERVICE, host, port },
		{ '-setwebproxystate', NETWORK_SERVICE, 'on' },
		{ '-setsecurewebproxystate', NETWORK_SERVICE, 'on' },
		{ '-setsocksfirewallproxystate', NETWORK_SERVICE, 'on' },
	}
end

-- 依次执行一串 networksetup 命令，全部成功才回调 true；任一失败立即终止并
-- 回调 false。逐条执行比单条 -setproxystate 重试更直观，且授权只会出现在第一次。
local function runCommandSequence(commands, done)
	local index = 1
	local function step()
		if index > #commands then
			done(true)
			return
		end
		local args = commands[index]
		local task = hs.task.new(NETWORKSETUP_PATH, function(exitCode, _, stdErr)
			if exitCode == 0 then
				index = index + 1
				step()
			else
				local msg = trim(stdErr)
				if msg == '' then
					msg = 'exit code ' .. tostring(exitCode)
				end
				log.ef('networksetup 失败 [%s]：%s', table.concat(args, ' '), msg)
				done(false, msg)
			end
		end, args)
		if task == nil or not task:start() then
			done(false, '无法启动 networksetup')
		end
	end
	step()
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
		{ key = 'web', args = { '-getwebproxy', NETWORK_SERVICE } },
		{ key = 'secure', args = { '-getsecurewebproxy', NETWORK_SERVICE } },
		{ key = 'socks', args = { '-getsocksfirewallproxy', NETWORK_SERVICE } },
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
		runCommandSequence(proxyCommands(action), function(ok, failureMessage)
			if not ok then
				hs.alert.show('代理切换失败：' .. (failureMessage or '未知错误'), { duration = 3 })
				return
			end

			-- 回读验证（macOS 生效可能有极短延迟），成功才算完成
			-- 全局变量持有 timer 防 GC
			proxy_verify_timer = hs.timer.doAfter(0.5, function()
				readProxyState(function(newState)
					if proxyStateMatches(newState, action) then
						currentAction = action
						local text = '已切换为' .. profile.name
						if profile.host then
							text = string.format('%s（%s:%d）', text, profile.host, PROXY_PORT)
						end
						hs.notify.new({
							title = 'Hammerspoon',
							informativeText = text,
						}):send()
					else
						log.e('代理切换后状态校验失败：期望 %s，实际 %s', action, describe(newState))
						hs.alert.show('代理切换未生效，请检查网络设置', { duration = 3 })
					end
				end)
			end)
		end)
	end)
end

-- 面板「查看代理状态」用：刷新后回调返回当前状态描述。
function describe(state)
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

-- 启动时自动选择可用代理：按顺序探测各 profile 的端口连通性，
-- 第一个能连通的设为系统代理；都不可达则保持系统现状。
local STARTUP_PROBE_ORDER = { 'local', 'remote' } -- 探测优先级，本机优先
local STARTUP_PROBE_DELAY = 5 -- 启动延迟（秒），等网络与代理客户端就绪

-- nc -z -G 2：仅探测 TCP 连通性不传输数据，2 秒超时
local function probePort(host, port, callback)
	local task = hs.task.new('/usr/bin/nc', function(exitCode)
		callback(exitCode == 0)
	end, { '-z', '-G', '2', host, tostring(port) })
	if task == nil or not task:start() then
		callback(false)
	end
end

local function autoConnectProxy(index)
	local action = STARTUP_PROBE_ORDER[index]
	if action == nil then
		log.w('启动代理探测：所有 profile 均不可达，保持系统现状')
		return
	end
	probePort(PROFILES[action].host, PROXY_PORT, function(reachable)
		if not reachable then
			autoConnectProxy(index + 1)
			return
		end
		log.i('启动代理探测：' .. action .. ' 可达')
		-- 探测阶段先判断：当前系统代理已是该目标则直接结束，不发起切换
		readProxyState(function(state)
			if proxyStateMatches(state, action) then
				currentAction = action
				log.i('当前系统代理已是 ' .. action .. '，无需切换')
				return
			end
			setProxy(action)
		end)
	end)
end

-- 全局变量持有 timer 防 GC：hs.timer 不被 Lua 引用时可能被回收，回调永不触发
proxy_startup_timer = hs.timer.doAfter(STARTUP_PROBE_DELAY, function()
	autoConnectProxy(1)
end)

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
