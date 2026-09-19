-- ===================================================
-- Ghostty 智能输入法切换：命令输入时自动临时切英文
--
-- 场景一：中文输入状态下，双击触发（第二下在窗口期内）：
--   - 「//」→ 第二个被吞掉，只留一个「/」，切英文
--   - 「!!」→ 吞掉第二个，退格删掉第一个「！」，切英文后补发一个英文「!」
--   恢复：Tab / Enter / Esc；立即按 Backspace（还没输入其他字符）也算取消
--   单个「/」「!」不触发切换（「!」正常输出「！」）
-- 场景二：按 F1 → 临时切到英文，再按任意其他键后切回原输入法
--   （触发恢复的那个键先以英文送达，之后才切回）
--
-- 原理：eventtap 监听 keyDown；
--   - 第一个触发键放行（输出「/」或「！」），记录待决状态等第二次按下
--   - 窗口期内第二个同键被拦截，按各键配置吞掉/删字/补发，并临时切英文
--     （第二个按键是真实物理事件，切换在它送达前生效，不存在补发丢失问题）
--   - 临时英文期间记录原输入法，恢复键按下时切回
--   - 焦点切换时兜底切回，避免把英文状态带去其他应用
-- ===================================================

-- 需要生效的应用
local TARGET_APPS = {
  ['Ghostty'] = true,
}

-- 中文输入法 Source ID（只在这些输入法下触发）
local CHINESE_SOURCE_IDS = {
  ['com.tencent.inputmethod.wetype.pinyin'] = true, -- 微信输入法
  ['com.apple.inputmethod.SCIM.ITABC'] = true,       -- 系统简中拼音
}

-- 临时切到的英文输入法（layout 名，与 InputSourceSwitch 保持一致）
local ENGLISH_SOURCE = 'ABC'

-- 双击判定窗口（秒）：两次按下间隔不超过此值才算双击
local DOUBLE_TAP_WINDOW = 0.35

-- 双击触发后动作的延迟（秒）：等第一个字符落定
local ACTION_DELAY = 0.02
-- 切英文后到补发的延迟（秒）：等输入法切换传播到应用
local RESEND_DELAY = 0.15

-- 补发前确认输入法已切到位（layout Source ID）
local ENGLISH_SOURCE_ID = 'com.apple.keylayout.ABC'

-- 双击触发的按键配置（keycode → 行为）
--   delete_first：是否退格删掉第一个键产生的字符
--   resend：切英文后补发几个「!」（用 keyStrokes，带按键间延迟，避免被应用输入上下文吞掉）
--   shifted：该键是否需要 shift 标志（「!」= shift+1）
local TRIGGER_KEYS = {
  [hs.keycodes.map['/']] = { delete_first = false, resend = 0, shifted = false },
  [hs.keycodes.map['1']] = { delete_first = true, resend = 1, shifted = true },
}

-- 场景一的恢复键（keycode）；Backspace 特殊处理：仅在未输入其他字符时恢复
local RESTORE_KEYS = {
  [hs.keycodes.map['tab']] = true,    -- Tab
  [hs.keycodes.map['return']] = true, -- 回车
  [76] = true,                        -- 小键盘回车（kVK_ANSI_KeypadEnter）
  [hs.keycodes.map['escape']] = true, -- Esc（取消搜索时也恢复）
}

local F1_KEYCODE = hs.keycodes.map['f1']            -- 122
local BACKSPACE_KEYCODE = hs.keycodes.map['delete'] -- 51

-- 临时英文状态：{ saved = 切走前的 Source ID, reason = 'double' | 'f1', typed = 触发后是否输入过其他字符 }
-- 待决双击状态：{ t = 第一下时间戳(纳秒), keycode, shifted }
-- 用全局引用，防止对象被 GC 导致监听失效
local logger = hs.logger.new('smart_ime', 'info')
smart_ime_state = nil
smart_ime_pending = nil
smart_ime_resend = 0
smart_ime_busy = false
smart_ime_tap = nil
smart_ime_focus_watcher = nil

local function isChineseSource()
  return CHINESE_SOURCE_IDS[hs.keycodes.currentSourceID()] ~= nil
end

local function inTargetApp()
  local app = hs.application.frontmostApplication()
  return app ~= nil and TARGET_APPS[app:name()] ~= nil
end

-- 硬修饰键（不含 shift/fn：shift 是「!」的一部分，F1 自带 fn）
local function hasHardMods(event)
  local flags = event:getFlags()
  return flags.cmd or flags.alt or flags.ctrl
end

-- 切到英文并记录原输入法；成功返回 true
local function toEnglish(reason)
  local saved = hs.keycodes.currentSourceID()
  local ok = hs.keycodes.setLayout(ENGLISH_SOURCE)
  if not ok then ok = hs.keycodes.setMethod(ENGLISH_SOURCE) end
  if not ok then
    logger.w('切换到 ' .. ENGLISH_SOURCE .. ' 失败，不进入临时英文状态')
    return false
  end
  smart_ime_state = { saved = saved, reason = reason, typed = false }
  smart_ime_pending = nil
  return true
end

-- 切回原输入法
local function restore()
  local state = smart_ime_state
  if not state then return end
  smart_ime_state = nil
  smart_ime_resend = 0
  hs.keycodes.currentSourceID(state.saved)
end

-- 双击触发后的动作：删字 → 切英文 → 按需补发（全部异步，回调内同步 post 事件不可靠）
-- busy 期间 keyDown 一律放行且不参与判断（删字/补发的事件会穿过自己的 tap）
local function armDouble(cfg)
  smart_ime_busy = true
  hs.timer.doAfter(ACTION_DELAY, function()
    if cfg.delete_first then
      hs.eventtap.keyStroke({}, 'delete') -- 删掉第一个「！」
    end
    local switched = toEnglish('double')
    if switched and cfg.resend > 0 then
      smart_ime_resend = cfg.resend
      local function resendBang(attempt)
        hs.timer.doAfter(RESEND_DELAY, function()
          if hs.keycodes.currentSourceID() == ENGLISH_SOURCE_ID or attempt >= 3 then
            -- keyStrokes（非 keyStroke）：带按键间延迟、正确构造 shift 序列，
            -- fix_paste_blocking 在 Ghostty 粘贴文本即用它，可靠性已验证
            hs.eventtap.keyStrokes('!')
          else
            resendBang(attempt + 1) -- 输入法还没传播到位，再等一轮
          end
        end)
      end
      resendBang(1)
    end
    hs.timer.doAfter(ACTION_DELAY + RESEND_DELAY * 4 + 0.1, function()
      smart_ime_busy = false
    end)
  end)
end

local function handleKeyDown(event)
  local state = smart_ime_state

  -- 临时英文期间：只关心恢复键
  if state then
    local keycode = event:getKeyCode()
    if smart_ime_busy then
      -- 删字/补发动作进行中，自己的事件不参与恢复判断
      return false
    end
    if state.reason == 'double' then
      if RESTORE_KEYS[keycode] then
        restore()
      elseif keycode == BACKSPACE_KEYCODE then
        -- 只有立即删除（还没输入过其他字符）才恢复
        if not state.typed then restore() end
      else
        -- 输入了其他字符，之后 Backspace 不再恢复
        state.typed = true
      end
    elseif state.reason == 'f1' then
      if keycode ~= F1_KEYCODE then
        -- 延迟切回：让触发恢复的按键先以英文送达应用，
        -- 否则它会被切回来的中文 IME 拦进拼音候选
        local saved = state.saved
        smart_ime_state = nil
        hs.timer.doAfter(0.05, function()
          hs.keycodes.currentSourceID(saved)
        end)
      end
    end
    return false -- 所有按键都放行
  end

  -- 待决双击判定：窗口期内第二个同键 → 触发
  if smart_ime_pending then
    local p = smart_ime_pending
    local elapsed = (hs.timer.absoluteTime() - p.t) / 1e9
    local keycode = event:getKeyCode()
    local cfg = TRIGGER_KEYS[keycode]
    local shifted = event:getFlags().shift == true -- 归一化：无 shift 时是 nil，需转成 false
    if cfg
      and not hasHardMods(event)
      and p.keycode == keycode
      and p.shifted == shifted
      and elapsed <= DOUBLE_TAP_WINDOW then
      smart_ime_pending = nil
      armDouble(cfg)
      return true -- 吞掉第二个触发键
    end
    -- 窗口期内按了别的键，或已超时：取消待决
    smart_ime_pending = nil
  end

  if not inTargetApp() or not isChineseSource() then return false end
  if hasHardMods(event) then return false end

  local keycode = event:getKeyCode()
  local cfg = TRIGGER_KEYS[keycode]
  if cfg and cfg.shifted == (event:getFlags().shift == true) then
    -- 第一下：放行（「/」输出「/」、「!」输出「！」），等待窗口期内可能的第二次按下
    smart_ime_pending = { t = hs.timer.absoluteTime(), keycode = keycode, shifted = cfg.shifted }
    return false
  elseif keycode == F1_KEYCODE then
    toEnglish('f1') -- F1 本身放行，无需补发
  end
  return false
end

smart_ime_tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, handleKeyDown)
smart_ime_tap:start()

-- 焦点切换兜底：临时英文期间离开应用，切回原输入法
smart_ime_focus_watcher = hs.window.filter.new():subscribe(
  hs.window.filter.windowFocused,
  function()
    smart_ime_pending = nil
    if smart_ime_busy then return end
    if smart_ime_state then restore() end
  end
)
