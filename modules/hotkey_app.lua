--[[
  Hammerspoon 应用快速启动配置
  功能：使用自定义热键快速启动或切换到常用应用。
  使用列表（数组）结构来存储应用配置。
--]]

-- 导出应用列表供其他模块使用
-- 分层定义：先按 mods 分组，组内定义 apps 列表
local APP_GROUPS = {
  {
    mods = {'lOpt'},
    apps = {
      { key = 'f1', name = 'Obsidian' },
      { key = 'f2', name = 'Microsoft To Do', desc = 'To Do' },
      { key = 'f3', name = 'Google Chrome', desc = 'Chrome' },
      { key = 'f4', name = 'Safari' },
      { key = 'f5', name = 'Telegram' },
    },
  },
  {
    mods = {'lOpt'},
    apps = {
      { key = '1', name = 'Sublime Text' },
      { key = '2', name = 'Ghostty' },
      { key = '3', name = 'iTerm' },
      { key = '4', name = 'TRAE CN' },
      --{ key = 'f1', name = 'Antigravity' },
      { key = '5', name = 'Visual Studio Code', desc = 'VSCode' },
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

-- 加载 LeftRightHotkey Spoon，用于区分左右修饰键
hs.loadSpoon('LeftRightHotkey')

-- 3. 绑定热键逻辑
-- 使用 ipairs 遍历列表
for _, appConfig in ipairs(M.appList) do
  local mods = appConfig.mods
  local key = appConfig.key
  local appName = appConfig.name

  -- 定义热键处理函数
  local launchHandler = function()
    -- 使用 hs.application.launchOrFocus() 函数：
    -- 如果应用未运行，则启动它；如果已运行，则切换焦点到该应用。
    local app = hs.application.launchOrFocus(appName)

    -- 如果应用未找到或启动失败，发出通知
    if not app then
      hs.alert.show('未找到应用或启动失败: ' .. appName)
    end
  end

  -- 使用 LeftRightHotkey:bind 进行绑定。
  -- 将启动逻辑放在 pressedFn (按下时执行)，
  -- 释放和点击函数设置为 nil，以实现最快的响应速度。
  spoon.LeftRightHotkey:bind(mods, key, launchHandler, nil, nil)
end

-- 4. 绑定显示映射的快捷键 (rCtrl + /)
local function showMappingAlert()
  local message = ""
  -- 遍历 APP_LIST 列表并构建通知内容
  for _, appConfig in ipairs(M.appList) do
    -- 关键修正：使用 table.concat 将修饰键表连接成字符串，用 " + " 分隔
    local modsString = table.concat(appConfig.mods, ' + ')

    -- 构建消息格式：mods + key - desc
    message = message .. string.format("%s + %s - %s\n", modsString, appConfig.key, appConfig.desc)
  end

  if #message > 0 then
    message = message:sub(1, #message - 1)
  end

  hs.alert.show(message)
end

local displayKey = '/'
spoon.LeftRightHotkey:bind({'rCtrl'}, displayKey, showMappingAlert, nil, nil)

-- 5. 启动 LeftRightHotkey 监听
spoon.LeftRightHotkey:start()

return M
