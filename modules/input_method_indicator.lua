-- **************************************************
-- 输入法指示器（焦点窗口所在屏幕底部横条）
-- 规则：英文（ABC）灰色；微信输入法绿色；简体中文输入法红色；
--       键盘离线时优先显示橙色提醒
-- **************************************************

-- --------------------------------------------------
local ABC = 'com.apple.keylayout.ABC'
local ApplePinyin = 'com.apple.inputmethod.SCIM.ITABC'
local WeType = 'com.tencent.inputmethod.wetype.pinyin'

-- 指示器颜色（按输入法 Source ID 配置，选用亮色保证暗背景下可见）
local IME_TO_COLORS = {
  -- 系统默认英语
  [ABC] = {
    { hex = '#B0B0B0' }, -- 亮灰
  },
  -- 系统自带简中输入法
  [ApplePinyin] = {
    { hex = '#FF5252' }, -- 亮红
  },
  [WeType] = {
    { hex = '#00C853' }, -- 亮绿
  }
}
-- --------------------------------------------------

-- --------------------------------------------------
-- 指示器外观配置
-- --------------------------------------------------
-- 指示器长度（水平方向）
local LENGTH = 120
-- 指示器粗细（垂直方向）
local THICKNESS = 6
-- 闪烁次数与间隔（秒）：切换窗口时竖条亮灭提示
local FLASH_BLINKS = 2
local FLASH_INTERVAL = 0.15
-- 指示器透明度
local ALPHA = 0.85
-- 距底部边缘的间距
local MARGIN_BOTTOM = 3
-- 多个颜色之间线性渐变
local ALLOW_LINEAR_GRADIENT = false
-- 调试日志开关：复现「切换窗口不闪烁」时打开，到 Hammerspoon 控制台看事件顺序
local DEBUG = false
-- --------------------------------------------------
local function debugLog(...)
  if not DEBUG then return end
  print(string.format('[imi %.3f]', hs.timer.secondsSinceEpoch()), ...)
end
-- 键盘在线状态检测
-- --------------------------------------------------
-- 键盘离线时底部指示器显示的颜色（橙）
local NO_KEYBOARD_COLOR = { hex = '#FF8C00' }
-- 窗口移动/调整大小后，静置多久才重绘指示条（秒）
local MOVE_SETTLE_DELAY = 0.3
-- 键盘在线状态轮询间隔（秒）
local KEYBOARD_POLL_INTERVAL = 3
-- 键盘是否在线（系统枚举到任意键盘类 HID 设备即在线，不区分连接来源）
local keyboardOnline = true

-- 前置声明，供下方 pollKeyboard 引用
local update

-- 检测当前是否存在键盘类输入设备
local function hasKeyboard()
  -- UsagePage=1 (Generic Desktop), Usage=6 (Keyboard)
  local output = hs.execute('hidutil list --matching \'{"DeviceUsagePage":1,"DeviceUsage":6}\'')
  return output ~= nil and output:find('%S') ~= nil
end

-- 键盘在线状态变化时刷新指示器
local function pollKeyboard()
  local online = hasKeyboard()
  if online ~= keyboardOnline then
    keyboardOnline = online
    update()
  end
end

-- --------------------------------------------------
local canvases = {}
local barBlinkTimer = nil
local lastSourceID = nil

-- 绘制指示器（锚定到焦点窗口所在屏幕底部，水平居中；无焦点窗口时回退到鼠标所在屏幕）
local function draw(colors)
  local window = hs.window.focusedWindow()
  local screen = (window and window:screen()) or hs.mouse.getCurrentScreen()
  local frame = screen:fullFrame()

  local canvasW = LENGTH
  local canvasX = frame.x + (frame.w - LENGTH) / 2
  local canvasY = frame.y + frame.h - THICKNESS - MARGIN_BOTTOM
  local canvasH = THICKNESS

  local canvas = hs.canvas.new({ x = canvasX, y = canvasY, w = canvasW, h = canvasH })
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  canvas:alpha(ALPHA)

  if ALLOW_LINEAR_GRADIENT and #colors > 1 then
    local rect = {
      type = 'rectangle',
      action = 'fill',
      fillGradient = 'linear',
      fillGradientColors = colors,
      frame = { x = 0, y = 0, w = canvasW, h = canvasH }
    }
    canvas[1] = rect
  else
    local cellW = canvasW / #colors

    for j, color in ipairs(colors) do
      local startX = (j - 1) * cellW
      local startY = 0
      local rect = {
        type = 'rectangle',
        action = 'fill',
        roundedRectRadii = { xRadius = canvasH / 2, yRadius = canvasH / 2 },
        fillColor = color,
        frame = { x = startX, y = startY, w = cellW, h = canvasH }
      }
      canvas[j] = rect
    end
  end

  canvas:show()
  canvases[1] = canvas
end

-- 清除 canvas 上的内容
local function clear()
  for _, canvas in ipairs(canvases) do
    canvas:delete()
  end
  canvases = {}
end

-- 更新 canvas 显示
-- 键盘离线时无键盘色优先级最高，无论当前输入法是什么都显示它
function update(sourceID)
  clear()

  local colors
  if not keyboardOnline then
    colors = { NO_KEYBOARD_COLOR }
  else
    colors = IME_TO_COLORS[sourceID or hs.keycodes.currentSourceID()]
  end

  if colors then
    draw(colors)
  end
end

-- 竖条闪烁：先隐藏再显示，亮灭交替后恢复常亮（输入法变化时提示）
local function blinkBar()
  if not canvases[1] then return end
  if barBlinkTimer then barBlinkTimer:stop() end
  debugLog('blink: start')
  canvases[1]:hide() -- 立即先隐藏
  local toggles = 0
  barBlinkTimer = hs.timer.doEvery(FLASH_INTERVAL, function()
    if not canvases[1] then
      debugLog('blink: aborted (canvas gone)')
      barBlinkTimer:stop()
      return
    end
    toggles = toggles + 1
    if toggles % 2 == 1 then
      canvases[1]:show()
    else
      canvases[1]:hide()
    end
    if toggles >= FLASH_BLINKS * 2 - 1 then
      debugLog('blink: done')
      barBlinkTimer:stop()
      canvases[1]:show() -- 恢复常亮
    end
  end)
end

local function handleInputSourceChanged()
  local currentSourceID = hs.keycodes.currentSourceID()

  if lastSourceID ~= currentSourceID then
    -- 输入法变化：重绘 + 闪烁（跨屏也闪）
    debugLog('event: TIS notify -> IME changed, redraw + blink', lastSourceID, '->', currentSourceID)
    update(currentSourceID)
    blinkBar()
  else
    debugLog('event: TIS notify -> IME unchanged, ignored', currentSourceID)
  end
  lastSourceID = currentSourceID
end

-- 输入法变化事件监听
-- 通过 hs.keycodes.inputSourceChanged 方式监听有时候不触发，直接监听系统事件可以解决，
-- 参考 https://github.com/Hammerspoon/hammerspoon/issues/1499
imi_dn = hs.distributednotifications.new(
  handleInputSourceChanged,
  -- or 'AppleSelectedInputSourcesChangedNotification'
  'com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged'
)
-- 屏幕变化时候重新渲染
-- screen.watcher 回调会把 watcher 对象传给 update，需要包一层避免被当作 sourceID
imi_screenWatcher = hs.screen.watcher.new(function() update() end)

imi_dn:start()
imi_screenWatcher:start()

-- 窗口焦点切换：重绘跟随焦点窗口所在屏幕（不闪烁，闪烁仅响应输入法变化）
-- 窗口移动/调整大小：先隐藏指示条，静置 MOVE_SETTLE_DELAY 后再重绘显示
-- （避免拖动过程中指示条每帧重绘、闪烁定时器与隐藏状态互相打架）
local moveSettleTimer = nil
local function handleWindowMoved()
  if barBlinkTimer then
    barBlinkTimer:stop()
    barBlinkTimer = nil
  end
  if canvases[1] then
    canvases[1]:hide()
  end
  if moveSettleTimer then moveSettleTimer:stop() end
  moveSettleTimer = hs.timer.doAfter(MOVE_SETTLE_DELAY, function()
    moveSettleTimer = nil
    update()
  end)
end

imi_windowFilter = hs.window.filter.new()
  :subscribe(
    hs.window.filter.windowFocused,
    function() update() end
  )
  :subscribe(
    hs.window.filter.windowMoved,
    handleWindowMoved
  )

-- 键盘在线状态轮询
imi_keyboardTimer = hs.timer.doEvery(KEYBOARD_POLL_INTERVAL, pollKeyboard)
imi_keyboardTimer:start()

-- 初始执行一次（先同步一次键盘在线状态）
keyboardOnline = hasKeyboard()
update()
