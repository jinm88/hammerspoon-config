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
    if device.vendorID then
        local vid = string.format("0x%04X", device.vendorID)
        if BLACKLIST.vendor_ids[vid] then
            return true
        end
    end
    if device.name then
        if BLACKLIST.device_names[device.name] then
            return true
        end
    end
    return false
end

local bluetoothWatcher = nil

function M.startWatcher()
    if bluetoothWatcher then
        print("[CmdOptSwap] watcher already running")
        return
    end

    bluetoothWatcher = hs.bluetooth.watcher.new(function(event, device)
        print("[CmdOptSwap] bluetooth event:", event)
        if event == "connected" then
            print("[CmdOptSwap] device connected:", device.name or "unknown", "vid:", device.vendorID or "n/a")
            if not M.isBlacklisted(device) then
                print("[CmdOptSwap] 非黑名单设备，执行交换")
                M.swapKeyboardModifiers()
            else
                print("[CmdOptSwap] 设备在黑名单中，跳过")
            end
        elseif event == "disconnected" then
            print("[CmdOptSwap] device disconnected:", device.name or "unknown")
            M.restoreKeyboardModifiers()
        end
    end)

    bluetoothWatcher:start()
    print("[CmdOptSwap] 蓝牙监听已启动")
end

function M.stopWatcher()
    if bluetoothWatcher then
        bluetoothWatcher:stop()
        bluetoothWatcher = nil
        print("[CmdOptSwap] 蓝牙监听已停止")
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