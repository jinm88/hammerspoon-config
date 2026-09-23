--[[
  Hammerspoon 应用快速启动配置
  功能：使用自定义热键快速启动或切换到常用应用。
  使用列表（数组）结构来存储应用配置。
--]]

-- 导出应用列表供其他模块使用
-- 分层定义：先按 mods 分组，组内定义 apps 列表2
local APP_GROUPS = {
  {
    mods = {'lOpt'},
    apps = {
      { key = 'f1', name = 'Microsoft To Do', desc = 'To Do' },
      { key = 'f2', name = 'Obsidian' },
      { key = 'f3', name = 'Google Chrome', desc = 'Chrome' },
      { key = 'f4', name = 'Telegram' },
      { key = 'f5', name = 'Safari' },
    },
  },
  {
    mods = {'lCmd'},
    apps = {
      { key = 'f1', name = 'Hermes' },
      { key = 'f2', name = 'Ghostty' },
      { key = 'f3', name = 'iTerm' },
      { key = 'f4', name = 'Sublime Text' },
      { key = 'f5', name = 'Visual Studio Code', desc = 'VSCode' },
      --{ key = 'f1', name = 'Antigravity' },
    },
  },
}

-- 将分层结构展平为扁平列表，确保下游遍历逻辑无需修改
local APP_LIST = {}
for _, group in ipairs(APP_GROUPS) do
  for _, app in ipairs(group.apps) do
    table.insert(APP_LIST, {
      mods = group.mods,
      key = app.key,
      name = app.name,
      desc = app.desc,
    })
  end
end

-- 填充缺失的 desc，如果 desc 为空则与 name 相同
for _, app in ipairs(APP_LIST) do
  if not app.desc or app.desc == '' then
    app.desc = app.name
  end
end

-- 导出配置
local M = { appList = APP_LIST }

----------------------------------------------------

----------------------------------------------------
-- 与方向键模块相同的实现：keyDown eventtap 实时读取设备级左右修饰键，
-- 不依赖 LeftRightHotkey 的「flagsChanged → 动态注册 hs.hotkey」机制，
-- 避免漏注册和必须 Reload 的完全失效。

local RAW = hs.eventtap.event.rawFlagMasks
local DEVICE_BITS = {
  lcmd = RAW.deviceLeftCommand,   rcmd = RAW.deviceRightCommand,
  lshift = RAW.deviceLeftShift,   rshift = RAW.deviceRightShift,
  lopt = RAW.deviceLeftAlternate, ropt = RAW.deviceRightAlternate,
  lctrl = RAW.deviceLeftControl,  rctrl = RAW.deviceRightControl,
}
local ALL_DEVICE_MASK = 0
for _, bit in pairs(DEVICE_BITS) do ALL_DEVICE_MASK = ALL_DEVICE_MASK | bit end

local function modBit(name)
  local n = name:lower()
  n = n:gsub('alt$', 'opt'):gsub('option$', 'opt'):gsub('control$', 'ctrl'):gsub('command$', 'cmd')
  return DEVICE_BITS[n]
end

-- 动作表：keycode + 精确修饰位掩码 → 动作函数
local ACTIONS = {}
local function addAction(mods, key, action)
  local mask = 0
  for _, m in ipairs(mods) do mask = mask | assert(modBit(m), '未知修饰键: ' .. m) end
  table.insert(ACTIONS, { keycode = hs.keycodes.map[key], modmask = mask, action = action })
end

-- 3. 绑定应用启动热键
for _, appConfig in ipairs(M.appList) do
  local appName = appConfig.name
  addAction(appConfig.mods, appConfig.key, function()
    -- 未运行则启动，已运行则切换焦点
    if not hs.application.launchOrFocus(appName) then
      hs.alert.show('未找到应用或启动失败: ' .. appName)
    end
  end)
end

-- 4. 显示映射的快捷键 (rCtrl + /)
local function showMappingAlert()
  local rows = {}
  for _, appConfig in ipairs(APP_LIST) do
    table.insert(rows, string.format('%s + %s - %s',
      table.concat(appConfig.mods, ' + '), appConfig.key, appConfig.desc))
  end
  hs.alert.show(table.concat(rows, '\n'))
end
addAction({'rCtrl'}, '/', showMappingAlert)

local function handleAppHotkey(event)
  local held = event:getRawEventData().CGEventData.flags & ALL_DEVICE_MASK
  local keycode = event:getKeyCode()
  for _, a in ipairs(ACTIONS) do
    if keycode == a.keycode and held == a.modmask then
      a.action()
      return true
    end
  end
  return false
end

-- 5. 通过 eventtap 健康守护注册
local health = package.loaded['modules.eventtap_health']
if health then
  health.register(function()
    return hs.eventtap.new({ hs.eventtap.event.types.keyDown }, handleAppHotkey):start()
  end, 'app_hotkeys')
end

return M
