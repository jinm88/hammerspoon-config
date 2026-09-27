-- WiFi 断联通知（事件驱动，无定时轮询）

-- 上一次连接的 WiFi 名称（用于断网通知中展示）
local lastWifiName = nil
-- 是否已针对本次断网弹过通知（防止 watcher 多次回调重复弹窗）
local disconnectNotified = false

-- WiFi 状态变化回调
local function updateWifiStatus()
	local wifiName = hs.wifi.currentNetwork()
	if wifiName == nil then
		-- 仅在「曾连接过 -> 断开」的状态跳变时通知一次
		-- 开机时 WiFi 尚未关联（lastWifiName 为 nil）不视为断网，避免误报
		if lastWifiName and not disconnectNotified then
			local text = "WiFi 已断开连接（\"" .. lastWifiName .. "\"）"
			hs.notify.new({ title = "Hammerspoon", informativeText = text }):send()
			disconnectNotified = true
		end
	else
		-- disconnectNotified 为 true 表示刚从断开状态恢复，此时弹重连通知
		local wasDisconnected = disconnectNotified
		lastWifiName = wifiName
		disconnectNotified = false
		if wasDisconnected then
			hs.notify.new({
				title = "Hammerspoon",
				informativeText = "WiFi 已连接：" .. wifiName,
			}):send()
		end
	end
end

-- 必须用全局变量持有 watcher，否则局部引用会被 Lua GC 回收，导致监控失效
wifi_watcher = hs.wifi.watcher.new(updateWifiStatus)
wifi_watcher:start()

-- WiFi 未连接时自动开启（每 60 秒检查一次）
local function checkAndEnableWifi()
	local interfaces = hs.wifi.interfaces()
	if interfaces and #interfaces > 0 and hs.wifi.currentNetwork() == nil then
		hs.wifi.setPower(true, interfaces[1])
	end
end

-- 同样用全局变量持有 timer 防 GC
wifi_check_timer = hs.timer.new(60, checkAndEnableWifi)
wifi_check_timer:start()

-- 首次加载脚本时，初始化当前网络状态
updateWifiStatus()
