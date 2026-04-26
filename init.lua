-- 关闭 hs.hotkey 的日志输出
hs.hotkey.setLogLevel('warning')

-- 配置定位服务权限，获取wifi需要用到
-- print(hs.location.get())
-- require('modules.caffeine')
-- require('modules.wifi_mute')

require('modules.feat_ocr')
require('modules.hotkey_app')
require('modules.hotkey_arrow_keys')
require('modules.auto_switch_input_method')
require('modules.auto_switch_audio')
require('modules.auto_swap_cmd_opt')
require('modules.fix_paste_blocking')
require('modules.indicator_input_method')
require('modules.fix_smooth_scrolling')
require('modules.feat_peek_app')
require('modules.feat_wifi_status')

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
