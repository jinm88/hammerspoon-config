-- 关闭 hs.hotkey 的日志输出
hs.hotkey.setLogLevel('warning')

-- 只需要引入 ipc 模块，Hammerspoon 就会自动开启内部默认的命令行监听端口
require("hs.ipc")


-- 配置定位服务权限，获取wifi需要用到
-- print(hs.location.get())
-- require('modules.caffeine')
-- require('modules.wifi_mute')

require('modules.feat_ocr')
require('modules.hotkey_app')
require('modules.hotkey_arrow_keys')
require('modules.auto_switch_audio')
require('modules.fix_paste_blocking')
require('modules.fix_smooth_scrolling')
require('modules.feat_peek_app')
require('modules.feat_wifi_status')
require('modules.input_method_indicator')
require('modules.fix_cursor_leak')
require('modules.fix_halfwidth_punct')

-- 显示所有快捷键映射
local function showAllHotkeys()
  local message = ""
  
  local appList = package.loaded['modules.hotkey_app'].appList
  local keyList = package.loaded['modules.hotkey_arrow_keys'].keyList

  -- 获取当前前台应用信息
  local frontApp = hs.application.frontmostApplication()
  local appName = frontApp:name()
  local appBundleId = frontApp:bundleID()
  local appPath = frontApp:path()

  message = message .. string.format("%s - %s\n\n", appName, appBundleId, appPath)
  message = message .. "=== App Hotkeys ===\n"
  local lastMods = nil
  for _, appConfig in ipairs(appList) do
    local modsString = table.concat(appConfig.mods, ' + ')
    -- 当 mods 变化时添加分隔线
    if lastMods and modsString ~= lastMods then
      message = message .. "---\n"
    end
    local displayName = appConfig.desc and appConfig.desc ~= '' and appConfig.desc or appConfig.name
    message = message .. string.format("%s + %s - %s\n", modsString, appConfig.key, displayName)
    lastMods = modsString
  end

  message = message .. "\n=== Arrow Keys ===\n"
  for _, config in ipairs(keyList) do
    if config.desc then
      local modsString = table.concat(config.mods, ' + ')
      message = message .. string.format("%s + %s - %s\n", modsString, config.key, config.desc)
    end
  end

  hs.alert.show(message, 5, {textSize = 20, fadeInDuration = 0.1, fadeOutDuration = 0.1})
end

-- 绑定显示所有快捷键的快捷键
hs.hotkey.bind({'cmd', 'alt', 'ctrl'}, '/', showAllHotkeys)

-- --------------------------------------------------
-- Spoons（由 SpoonInstall 统一管理，缺失的 Spoon 会从官方仓库自动下载安装）
-- --------------------------------------------------
hs.loadSpoon('SpoonInstall')
spoon.SpoonInstall.use_syncinstall = true
local Install = spoon.SpoonInstall

-- 输入法名称（InputSourceSwitch 用名称而非 sourceID）
-- 本机输入法名称可在 Hammerspoon Console 执行 hs.inspect(hs.keycodes.methods()) 查看
local WeType = '微信输入法'

-- 根据 App 自动切换输入法
Install:andUse('InputSourceSwitch', {
  fn = function(app)
    app:setApplications({
      ['终端'] = 'ABC',
      ['Ghostty'] = WeType,
      ['iTerm2'] = 'ABC',
      ['Visual Studio Code'] = 'ABC',
      ['Sublime Text'] = 'ABC',
      ['CotEditor'] = 'ABC',
      ['WebStorm'] = 'ABC',
      ['Obsidian'] = WeType,
      ['WeChat'] = WeType,
      ['Telegram'] = WeType,
    })
    app:start()
  end
})

-- 划词翻译
Install:andUse('PopupTranslateSelection', {
  hotkeys = {
    translate = { {'alt', 'shift'}, 'e' },
  }
})
