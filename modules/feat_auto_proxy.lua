-- 手动切换系统 HTTP/HTTPS/SOCKS 代理（由命令面板 feat_command_palette 调用）。
--
-- 直接调用 /usr/sbin/networksetup，不再依赖 setuid helper。首次执行某个动作时
-- macOS 会弹一次管理员授权，之后该动作即被记住、可静默执行。networksetup 参数
-- 均为模块内组装，不拼接 shell 命令、不接受外部输入。
--
-- 代理端点列表从配置文件 <configdir>/proxy_config.json 读取，只配置地址与
-- 端口（各端点端口独立）；文件缺失或非法时回退到内置默认值。
-- action 为端点数组下标（number）或 'off'。

local log = hs.logger.new('proxy', 'info')

local NETWORKSETUP_PATH = '/usr/sbin/networksetup'
local NETWORK_SERVICE = 'Wi-Fi'

local CONFIG_PATH = hs.configdir .. '/proxy_config.json'

-- 内置默认端点：与 proxy_config.json 保持一致
local DEFAULT_PROXIES = {
	{ host = '127.0.0.1', port = 7890 },
	{ host = '192.168.31.101', port = 7890 },
}

-- 校验并规范化 proxies 数组；合法返回 { { host, port }, ... }，非法返回 nil + 错误信息
local function validateProxies(value)
	if type(value) ~= 'table' or #value == 0 then
		return nil, 'proxies 必须是非空数组'
	end
	local proxies = {}
	for i, entry in ipairs(value) do
		if type(entry) ~= 'table' or type(entry.host) ~= 'string' or entry.host == '' then
			return nil, string.format('proxies[%d] 缺少 host', i)
		end
		local port = tonumber(entry.port)
		if port == nil or port % 1 ~= 0 or port < 1 or port > 65535 then
			return nil, string.format('proxies[%d]（%s）port 必须是 1-65535 的整数', i, tostring(entry.host))
		end
		proxies[i] = { host = entry.host, port = math.floor(port) }
	end
	return proxies
end

-- 读取代理端点配置；文件缺失或非法时回退内置默认
local function loadProxies()
	local file = io.open(CONFIG_PATH, 'r')
	if file == nil then
		log.i('未找到代理配置文件，使用内置默认：' .. CONFIG_PATH)
		return DEFAULT_PROXIES
	end
	local content = file:read('*a')
	file:close()

	local ok, decoded = pcall(hs.json.decode, content)
	if not ok or type(decoded) ~= 'table' then
		log.e('代理配置文件 JSON 解析失败，使用内置默认：' .. CONFIG_PATH)
		hs.alert.show('代理配置解析失败，使用默认配置', { duration = 3 })
		return DEFAULT_PROXIES
	end
	local proxies, err = validateProxies(decoded.proxies)
	if proxies == nil then
		log.ef('代理配置文件非法（%s），使用内置默认', err)
		hs.alert.show('代理配置非法：' .. err, { duration = 3 })
		return DEFAULT_PROXIES
	end
	log.i('已加载代理配置：' .. CONFIG_PATH)
	return proxies
end

-- 按配置顺序排列的代理端点：{ { host, port }, ... }
-- 数组顺序即面板展示顺序与启动探测顺序
local PROXIES = loadProxies()

-- action 合法性：PROXIES 下标（number）或 'off'
local function isValidAction(action)
	return action == 'off' or (type(action) == 'number' and PROXIES[action] ~= nil)
end

-- 展示用标签：端点为 host:port，关闭为固定文案
local function actionLabel(action)
	if action == 'off' then
		return '关闭代理'
	end
	local proxy = PROXIES[action]
	if proxy == nil then
		return tostring(action)
	end
	return string.format('%s:%d', proxy.host, proxy.port)
end

-- 当前本模块确认/设定的代理动作：PROXIES 下标（number）| 'off' | nil（未知）
local currentAction = nil

local describe -- 前向声明：setProxy 的回读校验会用到

local function trim(value)
	if value == nil then
		return ''
	end
	return (value:gsub('^%s*(.-)%s*$', '%1'))
end

-- 按 action 生成 networksetup 调用序列（参数均为模块内组装，无 shell 拼接）。
local function proxyCommands(action)
	if action == 'off' then
		return {
			{ '-setwebproxystate', NETWORK_SERVICE, 'off' },
			{ '-setsecurewebproxystate', NETWORK_SERVICE, 'off' },
			{ '-setsocksfirewallproxystate', NETWORK_SERVICE, 'off' },
		}
	end
	local proxy = PROXIES[action]
	local port = string.format('%d', proxy.port)
	return {
		{ '-setwebproxy', NETWORK_SERVICE, proxy.host, port },
		{ '-setsecurewebproxy', NETWORK_SERVICE, proxy.host, port },
		{ '-setsocksfirewallproxy', NETWORK_SERVICE, proxy.host, port },
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

	local proxy = PROXIES[action]
	return proxy ~= nil
		and state.web.enabled
		and state.secure.enabled
		and state.socks.enabled
		and state.web.server == proxy.host
		and state.secure.server == proxy.host
		and state.socks.server == proxy.host
		and state.web.port == proxy.port
		and state.secure.port == proxy.port
		and state.socks.port == proxy.port
end

-- 供命令面板调用：手动切换系统代理。action 为 PROXIES 下标（number）或 'off'。
local function setProxy(action)
	if not isValidAction(action) then
		log.ef('不支持的代理动作：%s', tostring(action))
		return
	end

	readProxyState(function(state)
		if proxyStateMatches(state, action) then
			currentAction = action
			log.i('当前系统代理已是目标状态（' .. actionLabel(action) .. '），无需修改')
			hs.alert.show('代理未变：' .. actionLabel(action), { duration = 1 })
			return
		end

		log.i('准备修改系统代理：' .. actionLabel(action))
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
						hs.notify.new({
							title = 'Hammerspoon',
							informativeText = '已切换为' .. actionLabel(action),
						}):send()
					else
						log.e('代理切换后状态校验失败：期望 %s，实际 %s', actionLabel(action), describe(newState))
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
		-- 能匹配已知端点/关闭状态时同步 currentAction，方便面板直接展示。
		local actions = { 'off' }
		for i in ipairs(PROXIES) do
			actions[#actions + 1] = i
		end
		for _, action in ipairs(actions) do
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

-- 启动时自动选择可用代理：按配置顺序探测各端点的端口连通性，
-- 第一个能连通的设为系统代理；都不可达则保持系统现状。
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
	local proxy = PROXIES[index]
	if proxy == nil then
		log.w('启动代理探测：所有端点均不可达，保持系统现状')
		return
	end
	probePort(proxy.host, proxy.port, function(reachable)
		if not reachable then
			autoConnectProxy(index + 1)
			return
		end
		log.i('启动代理探测：' .. actionLabel(index) .. ' 可达')
		-- 探测阶段先判断：当前系统代理已是该目标则直接结束，不发起切换
		readProxyState(function(state)
			if proxyStateMatches(state, index) then
				currentAction = index
				log.i('当前系统代理已是 ' .. actionLabel(index) .. '，无需切换')
				return
			end
			setProxy(index)
		end)
	end)
end

-- 全局变量持有 timer 防 GC：hs.timer 不被 Lua 引用时可能被回收，回调永不触发
proxy_startup_timer = hs.timer.doAfter(STARTUP_PROBE_DELAY, function()
	autoConnectProxy(1)
end)

return {
	-- 手动切换：setProxy(端点下标 | 'off')
	setProxy = setProxy,
	-- 查询状态：refreshStatus(fn(description, state))
	refreshStatus = refreshStatus,
	-- 当前本模块确认的代理动作：端点下标 | 'off' | nil（未知）
	current = function()
		return currentAction
	end,
	-- 按配置顺序排列的代理端点：{ { host, port }, ... }
	proxies = PROXIES,
}
