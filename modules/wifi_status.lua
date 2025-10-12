-- 创建一个用于显示 Wi-Fi 状态的 Canvas 变量
local wifiStatusCanvas = nil

-- 指示器高度
local HEIGHT = 4
-- 指示器透明度
local ALPHA = 1
-- 多个颜色之间线性渐变
local ALLOW_LINEAR_GRADIENT = false
-- 指示器颜色
local COLORS = {
	{ hex = '#de2910' },
	-- { hex = '#eab308' },
	-- { hex = '#0ea5e9' }
}
-- --------------------------------------------------

local canvases = {}
local lastSourceID = nil

-- 绘制指示器
local function draw(colors)
	local screens = hs.screen.allScreens()

	for i, screen in ipairs(screens) do
	local frame = screen:fullFrame()
	local canvasX = frame.x + frame.w - 64
	local canvasY = frame.y
	local canvasW = 64
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
			fillColor = color,
			frame = { x = startX, y = startY, w = cellW, h = canvasH }
		}
		canvas[j] = rect
		end
	end

	canvas:show()
	canvases[i] = canvas
	end
end

-- 清除 canvas 上的内容
local function clear()
	for _, canvas in ipairs(canvases) do
	canvas:delete()
	end
	canvases = {}
end

-- 更新 canvas 显示
local function updateWifiStatus(sourceID)
	clear()
	local wifiName = hs.wifi.currentNetwork()
	if wifiName == nil then
		draw(COLORS)
		hs.alert("[Status] WIFI down")
	end
end

-- 创建一个 Wi-Fi 观察者来监听状态变化
local wifiWatcher = hs.wifi.watcher.new(updateWifiStatus)

-- 启动观察者
wifiWatcher:start()

-- 首次加载脚本时，调用一次更新函数来设置初始状态
updateWifiStatus()
