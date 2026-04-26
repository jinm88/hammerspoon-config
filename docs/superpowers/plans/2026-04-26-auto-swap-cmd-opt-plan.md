# 蓝牙键盘修饰键自动交换模块实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 当连接蓝牙键盘时，自动将 Cmd 和 Opt 键交换，黑名单中的设备（苹果键盘）除外。

**Architecture:** 使用 `hs.bluetooth.watcher` 监听蓝牙设备连接事件，获取设备信息后检查黑名单，若不在黑名单中则通过 `hs.keycodes.masicap` 交换 Cmd 和 Opt 修饰键。

**Tech Stack:** Hammerspoon Lua API (`hs.bluetooth.watcher`, `hs.keycodes.masicap`)

---

## 文件结构

```
modules/
  auto_swap_cmd_opt.lua    # 新模块
```

---

## 实现计划

### Task 1: 创建模块文件

**Files:**
- Create: `modules/auto_swap_cmd_opt.lua`

- [ ] **Step 1: 创建模块文件**

```lua
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
```

- [ ] **Step 2: 提交**

```bash
git add modules/auto_swap_cmd_opt.lua
git commit -m "feat: initial module structure for cmd-opt swap"
```

---

### Task 2: 添加黑名单和设备检查逻辑

**Files:**
- Modify: `modules/auto_swap_cmd_opt.lua`

- [ ] **Step 1: 添加黑名单配置和检查函数**

```lua
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

return M
```

- [ ] **Step 2: 提交**

```bash
git add modules/auto_swap_cmd_opt.lua
git commit -m "feat: add blacklist and swap logic"
```

---

### Task 3: 添加蓝牙监听功能

**Files:**
- Modify: `modules/auto_swap_cmd_opt.lua`

- [ ] **Step 1: 添加蓝牙监听器**

```lua
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
```

- [ ] **Step 2: 在模块末尾添加自动启动**

```lua
-- 自动启动
M.startWatcher()
```

- [ ] **Step 3: 提交**

```bash
git add modules/auto_swap_cmd_opt.lua
git commit -m "feat: add bluetooth watcher for auto swap"
```

---

### Task 4: 在 init.lua 中引入模块

**Files:**
- Modify: `init.lua`

- [ ] **Step 1: 查看 init.lua 结构**

```bash
head -30 init.lua
```

- [ ] **Step 2: 添加模块引入**

在 `init.lua` 中找到其他 `require('modules.` 行，添加：

```lua
require('modules.auto_swap_cmd_opt')
```

- [ ] **Step 3: 提交**

```bash
git add init.lua
git commit -m "feat: enable auto swap cmd opt module"
```

---

### Task 5: 测试验证

- [ ] **Step 1: 重启 Hammerspoon 配置**

在 Hammerspoon 控制台执行：

```lua
hs.reload()
```

- [ ] **Step 2: 检查模块是否加载**

在 Hammerspoon 控制台执行：

```lua
require('modules.auto_swap_cmd_opt')
```

预期：输出 `[CmdOptSwap] 蓝牙监听已启动`

- [ ] **Step 3: 测试黑名单功能**

连接一个非苹果蓝牙键盘，检查 Cmd 和 Opt 键是否已交换。

---

## 验证清单

- [ ] 模块文件创建成功
- [ ] 黑名单配置正确（苹果 Vendor ID 0x05AC 在列表中）
- [ ] 蓝牙监听器启动无报错
- [ ] 连接蓝牙键盘时修饰键成功交换
- [ ] init.lua 中模块正确引入