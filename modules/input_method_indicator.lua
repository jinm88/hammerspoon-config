-- **************************************************
-- 输入法指示器（激活窗口左侧竖条）
-- 规则：英文（ABC）灰色；微信输入法绿色；简体中文输入法红色；
--       键盘离线时优先显示橙色提醒
-- **************************************************

-- --------------------------------------------------
local ABC = 'com.apple.keylayout.ABC'
local ApplePinyin = 'com.apple.inputmethod.SCIM.ITABC'
local WeType = 'com.tencent.inputmethod.wetype.pinyin'

-- 指示器颜色（按输入法 Source ID 配置）
local IME_TO_COLORS = {
  -- 系统默认英语
  [ABC] = {
    { hex = '#808080' }, -- 灰
  },
  -- 系统自带简中输入法
  [ApplePinyin] = {
    { hex = '#B22222' }, -- 红
  },
  [WeType] = {
    { hex = '#228B22' }, -- 绿
  }
}
-- --------------------------------------------------

-- --------------------------------------------------
-- 指示器外观配置
-- --------------------------------------------------
-- 指示器长度
local LENGTH = 120
-- 指示器粗细
local THICKNESS = 6
-- 闪烁次数与间隔（秒）：切换窗口时竖条亮灭提示
local FLASH_BLINKS = 2
local FLASH_INTERVAL = 0.15
-- 指示器透明度
local ALPHA = 0.6
-- 左边距（无激活窗口回退到屏幕时使用）
local MARGIN_LEFT = 3
-- 多个颜色之间线性渐变
local ALLOW_LINEAR_GRADIENT = false
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
local barBlinkTimer = nil
local lastSourceID = nil
local lastScreenID = nil

-- 绘制指示器（锚定到当前激活窗口；无激活窗口时回退到鼠标所在屏幕）
local function draw(colors)
  local window = hs.window.focusedWindow()
  local frame = window and window:frame() or hs.mouse.getCurrentScreen():fullFrame()

  local canvasW = THICKNESS
  local canvasX = window and frame.x or frame.x + MARGIN_LEFT
  local canvasY = frame.y + (frame.h - LENGTH) / 2
  local canvasH = LENGTH

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
    local cellH = canvasH / #colors

    for j, color in ipairs(colors) do
      local startX = 0
      local startY = (j - 1) * cellH
      local rect = {
        type = 'rectangle',
        action = 'fill',
        roundedRectRadii = { xRadius = canvasW / 2, yRadius = canvasW / 2 },
        fillColor = color,
        frame = { x = startX, y = startY, w = canvasW, h = cellH }
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
  canvases[1]:hide() -- 立即先隐藏
  local toggles = 0
  barBlinkTimer = hs.timer.doEvery(FLASH_INTERVAL, function()
    if not canvases[1] then
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
      barBlinkTimer:stop()
      canvases[1]:show() -- 恢复常亮
    end
  end)
end

local function handleInputSourceChanged()
  local currentSourceID = hs.keycodes.currentSourceID()
  local currentScreen = hs.mouse.getCurrentScreen()
  local currentScreenID = currentScreen and currentScreen:id()

  if lastScreenID ~= currentScreenID then
    -- 屏幕变化：只重绘，不闪烁
    update(currentSourceID)
  elseif lastSourceID ~= currentSourceID then
    -- 输入法变化：重绘 + 闪烁
    update(currentSourceID)
    blinkBar()
  end
  lastSourceID = currentSourceID
  lastScreenID = currentScreenID
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

-- 窗口焦点切换时：只重绘跟随新窗口（不闪烁，闪烁仅响应输入法变化）；拖动时跟随重绘
imi_windowFilter = hs.window.filter.new()
  :subscribe(
    hs.window.filter.windowFocused,
    function() update() end
  )
  :subscribe(
    hs.window.filter.windowMoved,
    function() update() end
  )

-- 键盘在线状态轮询
imi_keyboardTimer = hs.timer.doEvery(KEYBOARD_POLL_INTERVAL, pollKeyboard)
imi_keyboardTimer:start()

-- 初始执行一次（先同步一次键盘在线状态）
keyboardOnline = hasKeyboard()
update()
