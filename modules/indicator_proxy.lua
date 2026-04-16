-- **************************************************
-- 代理指示器
-- **************************************************

-- --------------------------------------------------
-- 配置
-- --------------------------------------------------
-- Unix socket 路径
local SOCKET_PATH = '/tmp/verge/verge-mihomo.sock'
-- API 端点
local API_PROXIES = 'http://localhost/proxies'
-- Clash Verge 配置文件路径
local CONFIG_PATH = os.getenv('HOME') .. '/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/verge.yaml'
-- 检查间隔（秒）- 备用轮询
local CHECK_INTERVAL = 30
-- 指示器宽度
local WIDTH = 120
-- 指示器高度
local HEIGHT = 4
-- 指示器透明度
local ALPHA = 0.8
-- 右上角边距
local MARGIN_TOP = 0
local MARGIN_RIGHT = 0
-- 不显示指示器的代理名称
local HIDDEN_PROXY_NAMES = {
  ['DIRECT'] = true,
  ['REJECT'] = true,
  ['REJECT-DROP'] = true,
  ['PASS'] = true,
  ['COMPATIBLE'] = true,
}
-- 指示器颜色
local PROXY_COLORS = {
  default = { hex = '#FF6B35' },  -- 橙红色
  safe = { hex = '#00D084' },     -- 绿色
}
-- --------------------------------------------------

local canvases = {}
local lastProxyName = nil
local configWatcher = nil
local checkTimer = nil

-- 通过 Unix socket 调用 Clash API
local function clashApiRequest()
  local cmd = string.format('curl -s --unix-socket %s %s', SOCKET_PATH, API_PROXIES)
  local handle = io.popen(cmd)
  if not handle then
    return nil
  end
  local result = handle:read('*a')
  handle:close()
  return result
end

-- 解析 JSON
local function parseJson(jsonStr)
  local ok, result = pcall(function(str)
    return hs.json.decode(str)
  end, jsonStr)
  if ok then
    return result
  end
  return nil
end

-- 获取当前代理名称
local function getCurrentProxyName()
  local response = clashApiRequest()
  if not response or response == '' then
    return nil
  end

  local data = parseJson(response)
  if not data or not data.proxies then
    return nil
  end

  -- 获取 Proxy 组当前选中的代理
  local proxyGroup = data.proxies['Proxy']
  if proxyGroup and proxyGroup.now then
    return proxyGroup.now
  end

  return nil
end

-- 判断是否应该显示指示器
local function shouldShowIndicator(proxyName)
  if not proxyName then
    return false
  end
  if HIDDEN_PROXY_NAMES[proxyName] then
    return false
  end
  if proxyName:find('BigMe') then
    return false
  end
  return true
end

-- 获取代理颜色
local function getProxyColor(proxyName)
  if proxyName:find('Auto') then
    return PROXY_COLORS.safe
  end
  return PROXY_COLORS.default
end

-- 为单个屏幕绘制指示器
local function drawForScreen(screen, proxyName)
  local frame = screen:fullFrame()

  -- 右上角位置
  local canvasX = frame.x + frame.w - WIDTH - MARGIN_RIGHT
  local canvasY = frame.y + MARGIN_TOP
  local canvasH = HEIGHT

  local canvas = hs.canvas.new({ x = canvasX, y = canvasY, w = WIDTH, h = canvasH })
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  canvas:alpha(ALPHA)

  local color = getProxyColor(proxyName)

  canvas[1] = {
    type = 'rectangle',
    action = 'fill',
    roundedRectRadii = { xRadius = canvasH / 2, yRadius = canvasH / 2 },
    fillColor = color,
    frame = { x = 0, y = 0, w = WIDTH, h = canvasH }
  }

  canvas:show()
  return canvas
end

-- 清除所有屏幕的指示器
local function clearAll()
  for _, canvas in pairs(canvases) do
    canvas:delete()
  end
  canvases = {}
end

-- 在所有屏幕绘制指示器
local function drawAll(proxyName)
  clearAll()

  local color = getProxyColor(proxyName)

  for _, screen in ipairs(hs.screen.allScreens()) do
    local frame = screen:fullFrame()
    local canvasX = frame.x + frame.w - WIDTH - MARGIN_RIGHT
    local canvasY = frame.y + MARGIN_TOP

    local canvas = hs.canvas.new({ x = canvasX, y = canvasY, w = WIDTH, h = HEIGHT })
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    canvas:alpha(ALPHA)

    canvas[1] = {
      type = 'rectangle',
      action = 'fill',
      roundedRectRadii = { xRadius = HEIGHT / 2, yRadius = HEIGHT / 2 },
      fillColor = color,
      frame = { x = 0, y = 0, w = WIDTH, h = HEIGHT }
    }

    canvas:show()
    table.insert(canvases, canvas)
  end
end

-- 更新指示器状态
local function update()
  local proxyName = getCurrentProxyName()

  if proxyName ~= lastProxyName then
    if shouldShowIndicator(proxyName) then
      drawAll(proxyName)
    else
      clearAll()
    end
    lastProxyName = proxyName
  end
end

-- 屏幕变化时重新绘制
local function onScreenChange()
  if lastProxyName and shouldShowIndicator(lastProxyName) then
    drawAll(lastProxyName)
  end
end

-- 初始化
local function init()
  -- 立即检查一次
  update()

  -- 监听配置文件变化（代理切换会写配置）
  configWatcher = hs.pathwatcher.new(CONFIG_PATH, function()
    update()
  end)
  configWatcher:start()

  -- 备用定时器轮询（防止漏检）
  checkTimer = hs.timer.new(CHECK_INTERVAL, function()
    update()
  end)
  checkTimer:start()

  -- 屏幕变化时重新绘制
  local screenWatcher = hs.screen.watcher.new(onScreenChange)
  screenWatcher:start()
end

-- 启动
init()
