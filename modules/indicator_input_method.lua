-- **************************************************
-- 输入法指示器
-- **************************************************

-- --------------------------------------------------
-- 指示器高度
local HEIGHT = 4
-- 指示器透明度
local ALPHA = 0.6
-- 底部边距
local MARGIN_BOTTOM = 3
-- 多个颜色之间线性渐变
local ALLOW_LINEAR_GRADIENT = false
-- 指示器颜色
local IME_TO_COLORS = {
  -- 系统默认英语
  ['com.apple.keylayout.ABC'] = {},
  -- 系统自带简中输入法
  ['com.apple.inputmethod.SCIM.ITABC'] = {
    { hex = '#B22222' }, -- 红
  },
  ['com.tencent.inputmethod.wetype.pinyin'] = {
    { hex = '#228B22' }, -- 绿
  }
}
-- --------------------------------------------------
-- 键盘在线状态检测
-- --------------------------------------------------
-- 键盘离线时底部指示器显示的颜色（橙）
local NO_KEYBOARD_COLOR = { hex = '#FF8C00' }
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
local lastSourceID = nil
local lastScreenID = nil

-- 绘制指示器
local function draw(colors)
  local screen = hs.mouse.getCurrentScreen()
  local frame = screen:fullFrame()

  local canvasW = 120
  local canvasX = frame.x + (frame.w - canvasW) / 2
  local canvasY = frame.y + frame.h - HEIGHT - MARGIN_BOTTOM
  local canvasH = HEIGHT

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

local function handleInputSourceChanged()
  local currentSourceID = hs.keycodes.currentSourceID()
  local currentScreen = hs.mouse.getCurrentScreen()
  local currentScreenID = currentScreen:id()

  if lastSourceID ~= currentSourceID or lastScreenID ~= currentScreenID then
    update(currentSourceID)
    lastSourceID = currentSourceID
    lastScreenID = currentScreenID
  end
end

-- 输入法变化事件监听
-- 通过 hs.keycodes.inputSourceChanged 方式监听有时候不触发，直接监听系统事件可以解决，
-- 参考 https://github.com/Hammerspoon/hammerspoon/issues/1499
imi_dn = hs.distributednotifications.new(
  handleInputSourceChanged,
  -- or 'AppleSelectedInputSourcesChangedNotification'
  'com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged'
)
-- 每秒同步一次，避免由于错过事件监听导致状态不同步
-- imi_indicatorSyncTimer = hs.timer.new(1, handleInputSourceChanged)
-- 屏幕变化时候重新渲染
-- screen.watcher 回调会把 watcher 对象传给 update，需要包一层避免被当作 sourceID
imi_screenWatcher = hs.screen.watcher.new(function() update() end)

imi_dn:start()
-- imi_indicatorSyncTimer:start()
imi_screenWatcher:start()

-- 键盘在线状态轮询
imi_keyboardTimer = hs.timer.doEvery(KEYBOARD_POLL_INTERVAL, pollKeyboard)
imi_keyboardTimer:start()

-- 初始执行一次（先同步一次键盘在线状态）
keyboardOnline = hasKeyboard()
update()
