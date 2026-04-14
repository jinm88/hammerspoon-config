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
local function update(sourceID)
  clear()

  local colors = IME_TO_COLORS[sourceID or hs.keycodes.currentSourceID()]

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
-- 参考 https://github.com/Hammerspoon/hammerspoon/issues/1499）
imi_dn = hs.distributednotifications.new(
  handleInputSourceChanged,
  -- or 'AppleSelectedInputSourcesChangedNotification'
  'com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged'
)
-- 每秒同步一次，避免由于错过事件监听导致状态不同步
imi_indicatorSyncTimer = hs.timer.new(1, handleInputSourceChanged)
-- 屏幕变化时候重新渲染
imi_screenWatcher = hs.screen.watcher.new(update)

imi_dn:start()
imi_indicatorSyncTimer:start()
imi_screenWatcher:start()

-- 初始执行一次
update()
