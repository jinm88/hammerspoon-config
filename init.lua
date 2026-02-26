-- 配置定位服务权限，获取wifi需要用到
-- print(hs.location.get())
-- require('modules.caffeine')
-- require('modules.wifi_mute')

require('modules.ocr')
require('modules.app_hotkey')
require('modules.arrow_keys_remapping')
require('modules.auto_switch_input_method')
require('modules.defeating_paste_blocking')
require('modules.input_method_indicator')
require('modules.magspeed_smooth_scrolling_fix')
require('modules.peek_app')
require('modules.wifi_status')

-- 显示所有快捷键映射
local function showAllHotkeys()
  local appList = package.loaded['modules.app_hotkey'].appList
  local keyList = package.loaded['modules.arrow_keys_remapping'].keyList

  local message = "=== App Hotkeys ===\n"
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
