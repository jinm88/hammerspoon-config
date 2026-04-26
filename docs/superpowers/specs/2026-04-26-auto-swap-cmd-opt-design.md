# 蓝牙键盘修饰键自动交换模块

**日期：** 2026-04-26

## 功能目标

当连接蓝牙键盘时，自动将 Cmd 和 Opt 键交换，黑名单中的设备除外。

## 黑名单配置

```lua
local BLACKLIST = {
    vendor_ids = {
        ["0x05AC"] = true,  -- Apple
    },
    device_names = {
        -- 例：["Magic Keyboard"] = true,
    },
}
```

## 核心逻辑

1. 监听蓝牙设备连接事件
2. 获取连接设备的 Vendor ID 和名称
3. 若既不在 vendor_id 黑名单，也不在 device_name 黑名单，则应用 Cmd↔Opt 交换

## 实现要点

- 使用 `hs.bluetooth.watcher` 监听蓝牙连接
- 通过 `hs.keycodes.masicap` 应用键位交换
- 代码中可编辑的黑名单配置

## 文件结构

```
modules/
  auto_swap_cmd_opt.lua    # 新模块
```

## 模块职责

- `isBlacklisted(device)` - 检查设备是否在黑名单
- `swapKeyboardModifiers()` - 交换所有非黑名单键盘的修饰键
- `startWatcher()` / `stopWatcher()` - 启动/停止蓝牙监听