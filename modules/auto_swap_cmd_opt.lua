-- **************************************************
-- 蓝牙键盘修饰键自动交换
-- **************************************************

local M = {}

-- 黑名单配置
local BLACKLIST = {
    vendor_ids = {
        -- Apple
        ["0x05AC"] = true,
    },
    device_names = {
        -- 例：["Magic Keyboard"] = true,
    },
}

local mods_swap = {
    left = "cmd",
    right = "opt",
}

local mods_swap_flipped = {
    left = "opt",
    right = "cmd",
}

-- 检查设备是否在黑名单中
function M.isBlacklisted(device)
    -- device 可能是 USB watcher 的 data 或分布式通知的 object
    local vendorID = device.vendorID or device.VendorID
    local productName = device.productName or device.name or device.product or device.DeviceName or ""

    if vendorID then
        local vid = string.format("0x%04X", vendorID)
        if BLACKLIST.vendor_ids[vid] then
            return true
        end
    end
    for _, name in pairs(BLACKLIST.device_names) do
        if string.find(productName, name, 1, true) then
            return true
        end
    end
    return false
end

local usbWatcher = nil
local distNoteWatcher = nil

-- 使用 USB watcher 监听设备连接
function M.startWatcher()
    if usbWatcher then
        print("[CmdOptSwap] watcher already running")
        return
    end

    usbWatcher = hs.usb.watcher.new(function(data)
        print("[CmdOptSwap] USB event:", data.eventType, "device:", data.productName or "unknown")
        if data.eventType == "added" then
            print("[CmdOptSwap] device connected:", data.productName or "unknown", "vid:", data.vendorID or "n/a")
            if not M.isBlacklisted(data) then
                print("[CmdOptSwap] 非黑名单设备，执行交换")
                M.swapKeyboardModifiers()
            else
                print("[CmdOptSwap] 设备在黑名单中，跳过")
            end
        elseif data.eventType == "removed" then
            print("[CmdOptSwap] device disconnected:", data.productName or "unknown")
            M.restoreKeyboardModifiers()
        end
    end)

    usbWatcher:start()
    print("[CmdOptSwap] USB 监听已启动")

    -- 使用分布式通知监听蓝牙设备变更
    distNoteWatcher = hs.distributednotifications.new(function(name, object, userInfo)
        print("[CmdOptSwap] distributed notification:", name, object)
        -- 监听蓝牙设备连接通知
        if name == "AppleBluetoothDeviceConnected" or name == "com.apple.bluetoothdDeviceConnected" then
            print("[CmdOptSwap] 蓝牙设备连接通知:", object)
            M.swapKeyboardModifiers()
        elseif name == "AppleBluetoothDeviceDisconnected" or name == "com.apple.bluetoothdDeviceDisconnected" then
            print("[CmdOptSwap] 蓝牙设备断开通知:", object)
            M.restoreKeyboardModifiers()
        end
    end, nil, nil)

    distNoteWatcher:start()
    print("[CmdOptSwap] 分布式通知监听已启动")
end

function M.stopWatcher()
    if usbWatcher then
        usbWatcher:stop()
        usbWatcher = nil
        print("[CmdOptSwap] USB 监听已停止")
    end
    if distNoteWatcher then
        distNoteWatcher:stop()
        distNoteWatcher = nil
        print("[CmdOptSwap] 分布式通知监听已停止")
    end
end

-- 销毁模块，停止所有 watcher
function M.destroy()
    M.stopWatcher()
    print("[CmdOptSwap] 模块已销毁")
end

-- 交换修饰键
function M.swapKeyboardModifiers()
    hs.keycodes.masicap(mods_swap)
end

-- 恢复修饰键
function M.restoreKeyboardModifiers()
    hs.keycodes.masicap(mods_swap_flipped)
end

-- 自动启动
M.startWatcher()

return M