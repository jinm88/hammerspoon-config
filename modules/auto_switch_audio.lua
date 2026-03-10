-- 1. 配置
local BLACKLIST = {
    "DJI Mic Mini-1B9775",
}
local CHECK_DELAY = 0.8
local lastValidDeviceUID = nil

-- 初始化：获取当前默认设备
local function initLastValidDevice()
    local currentDev = hs.audiodevice.defaultOutputDevice()
    if currentDev then
        lastValidDeviceUID = currentDev:uid()
        print("[AudioWatcher] 初始设备:", currentDev:name(), lastValidDeviceUID)
    end
end

-- 2. 逻辑函数
local function checkAndRestore()
    local currentDev = hs.audiodevice.defaultOutputDevice()
    local currentName = currentDev:name()

    print("[AudioWatcher] 当前设备:", currentName, currentDev:uid())

    -- 检查是否在黑名单中（精确匹配）
    local isBlacklisted = false
    for _, name in ipairs(BLACKLIST) do
        if currentName == name then
            isBlacklisted = true
            break
        end
    end

    if isBlacklisted then
        print("[AudioWatcher] 检测到黑名单设备，尝试恢复...")
        local backupDev = hs.audiodevice.findDeviceByUID(lastValidDeviceUID)
        if backupDev then
            print("[AudioWatcher] 切换到:", backupDev:name())
            local success = backupDev:setDefaultOutputDevice()
            print("[AudioWatcher] 切换结果:", success)
            hs.alert.show("音频自动切换: " .. currentName .. " → " .. backupDev:name())
        else
            print("[AudioWatcher] 未找到上一个有效设备")
        end
    else
        lastValidDeviceUID = currentDev:uid()
        print("[AudioWatcher] 更新有效设备:", lastValidDeviceUID)
    end
end

-- 3. 监听器
initLastValidDevice()
hs.audiodevice.watcher.setCallback(function(event)
    print("[AudioWatcher] 事件:", event)
    if event == "dev#" then
        hs.timer.doAfter(CHECK_DELAY, checkAndRestore)
    end
end)
hs.audiodevice.watcher.start()
print("[AudioWatcher] 已启动")