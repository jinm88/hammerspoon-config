-- **************************************************
-- 蓝牙键盘修饰键自动交换
-- **************************************************

local mods_swap = {
    left = "cmd",
    right = "opt",
}

local mods_swap_flipped = {
    left = "opt",
    right = "cmd",
}

return {
    mods_swap = mods_swap,
    mods_swap_flipped = mods_swap_flipped,
}