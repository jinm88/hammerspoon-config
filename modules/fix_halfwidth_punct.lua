-- ===================================================
-- 终端中文半角标点：微信输入法的「中英文标点切换」快捷键（alt+shift+.）
-- 进 Ghostty（中文输入时）→ 自动切到半角；
-- 离开 Ghostty（仍是中文输入时）→ 自动切回全角
-- ===================================================

-- 中文输入法 Source ID
local CHINESE_SOURCE_IDS = {
  ['com.tencent.inputmethod.wetype.pinyin'] = true, -- 微信输入法
  ['com.apple.inputmethod.SCIM.ITABC'] = true,      -- 系统简中拼音
}

-- 需要半角标点的应用
local TARGET_APPS = {
  ['Ghostty'] = true,
}

-- 要模拟的「中英文标点切换」快捷键
local HOTKEY_MODS = { 'alt', 'shift' }
local HOTKEY_KEY = '.'

-- 延迟触发（秒）：等切换完全落定
local TRIGGER_DELAY = 0.1

-- Hammerspoon 侧记录的标点模式：false = 全角，true = 半角
-- 注意：若你手动按过 alt+shift+. 切换，此记录会失真，reload Hammerspoon 可重置
local halfwidthMode = false

-- --------------------------------------------------
-- 自动切换：进目标应用切半角，离开切回全角
-- --------------------------------------------------
local function pressToggleHotkey()
  hs.timer.doAfter(TRIGGER_DELAY, function()
    hs.eventtap.keyStroke(HOTKEY_MODS, HOTKEY_KEY)
  end)
end

-- 统一判断：当前「中文输入法 + 是否在目标应用」与期望的标点模式是否一致
local function evaluate()
  local sourceID = hs.keycodes.currentSourceID()
  if not CHINESE_SOURCE_IDS[sourceID] then return end

  local app = hs.application.frontmostApplication()
  if not app then return end
  local inTarget = TARGET_APPS[app:name()] ~= nil

  if inTarget and not halfwidthMode then
    -- 进目标应用：切到半角
    halfwidthMode = true
    pressToggleHotkey()
  elseif not inTarget and halfwidthMode then
    -- 离开目标应用且仍是中文输入：切回全角
    halfwidthMode = false
    pressToggleHotkey()
  end
end

-- 输入法变化时判断
imi_punct_dn = hs.distributednotifications.new(
  evaluate,
  'com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged'
)
imi_punct_dn:start()

-- 窗口焦点切换时也判断（覆盖「同为中文输入法的应用间切换」不触发输入法通知的情况）
imi_punct_wf = hs.window.filter.new():subscribe(
  hs.window.filter.windowFocused,
  evaluate
)
