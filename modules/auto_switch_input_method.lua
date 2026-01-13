-- **************************************************
-- 根据 App 自动切换输入法
-- **************************************************

local utils = require('modules.utils')

-- --------------------------------------------------
local ABC = 'com.apple.keylayout.ABC'
local Pinyin = 'com.apple.inputmethod.SCIM.ITABC'
local WeType = 'com.tencent.inputmethod.wetype.pinyin'
-- defaults read ~/Library/Preferences/com.apple.HIToolbox.plist AppleSelectedInputSources
local CurrPinyin = Pinyin

-- 定义你自己想要自动切换输入法的 app
local APP_TO_IME = {
  ['/Applications/Alfred 5.app'] = ABC,
  ['/Applications/Terminal.app'] = ABC,
  ['/Applications/iTerm.app'] = ABC,
  ['/Applications/Visual Studio Code.app'] = ABC,
  ['/Applications/Sublime Text.app'] = ABC,
  ['/Applications/CotEditor.app'] = ABC,
  ['/Applications/WebStorm.app'] = ABC,
  -- ['/Applications/Arc.app'] = ABC,
  -- ['/Applications/Google Chrome.app'] = CurrPinyin,
  ['/Applications/Microsoft Edge.app'] = CurrPinyin,
  ['/Applications/Obsidian.app'] = CurrPinyin,
  ['/Applications/Microsoft To Do.app'] = CurrPinyin,
  ['/Applications/QQ.app'] = CurrPinyin,
  ['/Applications/WeChat.app'] = CurrPinyin,
  ['/Applications/企业微信.app'] = CurrPinyin,
  ['/Applications/DingTalk.app'] = CurrPinyin,
  ['/Applications/App.app'] = CurrPinyin,
}
-- --------------------------------------------------

local function updateFocusedAppInputMethod(appObject)
  local focusedAppPath = appObject:path()
  local ime = APP_TO_IME[focusedAppPath]

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
