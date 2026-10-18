--[[
  Hammerspoon 应用快速启动配置
  功能：使用自定义热键快速启动或切换到常用应用。
  使用列表（数组）结构来存储应用配置。
--]]

-- 导出应用列表供其他模块使用
-- 分层定义：先按 mods 分组，组内定义 apps 列表2
-- 一律用 bundleID 启动（hs.application.launchOrFocusByBundleID），
-- 避免同名 app 的名字解析歧义（如 Hermes 安装器 com.nousresearch.hermes.setup
-- 与桌面版 com.nousresearch.hermes 都叫 "Hermes"）。
-- name 仅用于 alert 展示。
local keyboardProfile = require('modules.keyboard_profile')

local APP_GROUPS = {
  {
    mods = {'lOpt'},
    apps = {
      { key = 'f1', name = 'Google Chrome', bundleID = 'com.google.Chrome' },
      { key = 'f2', name = 'Obsidian', bundleID = 'md.obsidian' },
      { key = 'f3', name = 'Microsoft To Do', desc = 'To Do', bundleID = 'com.microsoft.to-do-mac' },
      { key = 'f4', name = 'Telegram', bundleID = 'ru.keepcoder.Telegram' },
      { key = 'f5', name = 'Safari', bundleID = 'com.apple.Safari' },
    },
  },
  {
    mods = {'lCmd'},
    apps = {
      { key = 'f1', name = 'Hermes', bundleID = 'com.nousresearch.hermes' },
      { key = 'f2', name = 'Ghostty', bundleID = 'com.mitchellh.ghostty' },
      { key = 'f3', name = 'iTerm', bundleID = 'com.googlecode.iterm2' },
      { key = 'f4', name = 'Zed', desc = 'ZedG', bundleID = 'dev.zed.Zed' },
      { key = 'f5', name = 'Visual Studio Code', desc = 'VSCode', bundleID = 'com.microsoft.VSCode' },
      { key = 'f6', name = 'CotEditor', bundleID = 'com.coteditor.CotEditor' },
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
      bundleID = assert(app.bundleID, '缺少 bundleID: ' .. app.name),
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
  addAction(appConfig.mods, appConfig.key, function()
    -- 未运行则启动，已运行则切换焦点；按 bundleID 精确匹配，避免同名 app 歧义
    if not hs.application.launchOrFocusByBundleID(appConfig.bundleID) then
      hs.alert.show('未找到应用或启动失败: ' .. appConfig.name)
    end
  end)
end

-- 4. 显示当前应用信息 + 全部 app 快捷键（右侧修饰键随当前键盘变化）
local function showMappingAlert()
  local frontApp = hs.application.frontmostApplication()
  local rows = {
    string.format('%s | %s', frontApp:name(), frontApp:bundleID() or '-'),
    '--- App Hotkeys ---',
  }
  for _, appConfig in ipairs(APP_LIST) do
    table.insert(rows, string.format('%s + %s - %s',
      table.concat(appConfig.mods, ' + '), appConfig.key, appConfig.desc))
  end
  hs.alert.show(table.concat(rows, '\n'), { textSize = 18 }, 6)
end
local function handleAppHotkey(event)
  local held = event:getRawEventData().CGEventData.flags & ALL_DEVICE_MASK
  local keycode = event:getKeyCode()

  -- 显示映射的右侧修饰键跟随当前键盘变化，无需重建 eventtap
  if keycode == hs.keycodes.map['\\'] and held == assert(modBit(keyboardProfile.rightModifier)) then
    showMappingAlert()
    return true
  end

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
