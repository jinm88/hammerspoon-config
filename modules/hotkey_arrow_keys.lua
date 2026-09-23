-- **************************************************
-- 方向键映射
--
-- 直接用 keyDown eventtap 实时拦截，替代 LeftRightHotkey 的
-- 「flagsChanged → 动态 enable/disable hs.hotkey」机制：
-- 旧机制在修饰键与主键连按过快、Hammerspoon 主线程繁忙或 eventtap
-- 被系统超时时会漏注册，导致 opt+r 等组合原样透传（Ghostty 中
-- opt+r = Meta+r = readline revert-line，会把命令行删掉的内容
-- 整段恢复，表现为「输出一段字符」）。
-- 这里在每次 keyDown 时直接读取设备级左右修饰键状态，无注册竞态。
-- **************************************************

-- 应用列表格式 (类似 app_hotkey)
local KEY_LIST = {
  { mods = {'lOpt'}, key = 'w', target = 'up' },
  { mods = {'lOpt'}, key = 's', target = 'down' },
  { mods = {'lOpt'}, key = 'a', target = 'left' },
  { mods = {'lOpt'}, key = 'd', target = 'right' },
  { mods = {'lOpt'}, key = 'r', target = 'pageup', desc = 'PageUp' },
  { mods = {'lOpt'}, key = 'f', target = 'pagedown', desc = 'PageDown' },
  { mods = {'lOpt'}, key = 'q', target = 'home', desc = 'Home' },
  { mods = {'lOpt'}, key = 'e', target = 'end', desc = 'End' },

  { mods = {'lOpt'}, key = '[', target = 'pageup', desc = 'PageUp' },
  { mods = {'lOpt'}, key = ']', target = 'pagedown', desc = 'PageDown' },
  { mods = {'rOpt'}, key = '[', target = 'pageup', desc = 'PageUp' },
  { mods = {'rOpt'}, key = ']', target = 'pagedown', desc = 'PageDown' },
  -- { mods = {'rOpt'}, key = ';', target = 'home', desc = 'Home' },
  -- { mods = {'rOpt'}, key = '\'', target = 'end', desc = 'End' },
  { mods = {'rCtrl'}, key = '[', target = 'pageup', desc = 'PageUp' },
  { mods = {'rCtrl'}, key = ']', target = 'pagedown', desc = 'PageDown' },
  -- { mods = {'rCtrl'}, key = ';', target = 'home', desc = 'Home' },
  -- { mods = {'rCtrl'}, key = '\'', target = 'end', desc = 'End' },
}

-- 设备级修饰键位（raw flags，可区分左右）
local RAW = hs.eventtap.event.rawFlagMasks
local DEVICE_BITS = {
  lcmd   = RAW.deviceLeftCommand,
  rcmd   = RAW.deviceRightCommand,
  lshift = RAW.deviceLeftShift,
  rshift = RAW.deviceRightShift,
  lopt   = RAW.deviceLeftAlternate,
  ropt   = RAW.deviceRightAlternate,
  lctrl  = RAW.deviceLeftControl,
  rctrl  = RAW.deviceRightControl,
}
local ALL_DEVICE_MASK = 0
for _, bit in pairs(DEVICE_BITS) do ALL_DEVICE_MASK = ALL_DEVICE_MASK | bit end

-- 归一化配置里的修饰键名，并预计算每条绑定所需的精确修饰位掩码
-- （与 LeftRightHotkey 语义一致：按下的设备侧修饰键必须与定义完全相同）
local function modBit(name)
  local n = name:lower()
  n = n:gsub('alt$', 'opt'):gsub('option$', 'opt'):gsub('control$', 'ctrl'):gsub('command$', 'cmd')
  return DEVICE_BITS[n]
end

for _, cfg in ipairs(KEY_LIST) do
  local mask = 0
  for _, m in ipairs(cfg.mods) do
    local bit = assert(modBit(m), '未知修饰键: ' .. m)
    mask = mask | bit
  end
  cfg._modmask = mask
  cfg._keycode = hs.keycodes.map[cfg.key]
  cfg._target = hs.keycodes.map[cfg.target]
end

-- 导出配置
local M = { keyList = KEY_LIST }
----------------------------------------------------

local function handleKeyDown(event)
  local held = event:getRawEventData().CGEventData.flags & ALL_DEVICE_MASK
  local keycode = event:getKeyCode()
  for _, cfg in ipairs(KEY_LIST) do
    if keycode == cfg._keycode and held == cfg._modmask then
      local target = cfg._target
      -- 异步 post：回调内同步 post 事件不可靠；
      -- 显式传空 mods，即使物理 Opt 仍按住，合成事件也不带修饰标志
      hs.timer.doAfter(0, function()
        hs.eventtap.event.newKeyEvent({}, target, true):post()
        hs.eventtap.event.newKeyEvent({}, target, false):post()
      end)
      return true -- 吞掉原始按键（含透传成 ® / Meta+r 的可能）
    end
  end
  return false
end

-- 通过 eventtap 健康守护注册（自动处理系统禁用、唤醒后僵尸态、周期重建）
local health = package.loaded['modules.eventtap_health']
if health then
  health.register(function()
    return hs.eventtap.new({ hs.eventtap.event.types.keyDown }, handleKeyDown):start()
  end, 'arrow_keys')
end

return M
