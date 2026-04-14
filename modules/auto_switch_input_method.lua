-- **************************************************
-- 根据 App 自动切换输入法
-- **************************************************

local utils = require('modules.utils')

-- --------------------------------------------------
local ABC = 'com.apple.keylayout.ABC'
local ApplePinyin = 'com.apple.inputmethod.SCIM.ITABC'
local WeType = 'com.tencent.inputmethod.wetype.pinyin'
-- defaults read ~/Library/Preferences/com.apple.HIToolbox.plist AppleSelectedInputSources
local Pinyin = WeType

-- 定义你自己想要自动切换输入法的 app
local APP_TO_IME = {
  ['终端'] = Pinyin,
  ['Ghostty'] = Pinyin,
  ['iTerm2'] = ABC,
  ['Visual Studio Code'] = ABC,
  ['Sublime Text'] = ABC,
  ['CotEditor'] = ABC,
  ['WebStorm'] = ABC,
  ['Obsidian'] = Pinyin,
  ['WeChat'] = Pinyin,
  ['Telegram'] = Pinyin,
}
-- --------------------------------------------------

local function updateFocusedAppInputMethod(appObject)
  local focusedAppName = appObject:name()
  local ime = APP_TO_IME[focusedAppName]

  if ime then
    hs.keycodes.currentSourceID(ime)
  end
end
local debouncedUpdateFn = utils.debounce(updateFocusedAppInputMethod, 0.1)

asim_appWatcher = hs.application.watcher.new(
  function(appName, eventType, appObject)
    if eventType == hs.application.watcher.activated then
      debouncedUpdateFn(appObject)
    end
  end
)
asim_appWatcher:start()
