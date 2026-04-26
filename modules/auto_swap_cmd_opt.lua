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

-- 交换修饰键
function M.swapKeyboardModifiers()
    hs.keycodes.masicap(mods_swap)
end

-- 恢复修饰键
function M.restoreKeyboardModifiers()
    hs.keycodes.masicap(mods_swap_flipped)
end

local mods_swap = {
    left = "cmd",
    right = "opt",
}

local mods_swap_flipped = {
    left = "opt",
    right = "cmd",
}

return M