-- **************************************************
-- 根据 App 自动切换输入法
-- **************************************************

local utils = require('modules.utils')

-- --------------------------------------------------
local Pinyin = 'com.apple.inputmethod.SCIM.ITABC'
local ABC = 'com.apple.keylayout.ABC'

-- 定义你自己想要自动切换输入法的 app
local APP_TO_IME = {
  ['/Applications/Alfred 5.app'] = ABC,
  ['/Applications/Terminal.app'] = ABC ,
  ['/Applications/iTerm.app'] = ABC,
  ['/Applications/Visual Studio Code.app'] = ABC,
  ['/Applications/Sublime Text.app'] = ABC,
  ['/Applications/CotEditor.app'] = ABC,
  ['/Applications/WebStorm.app'] = ABC,
  ['/Applications/Arc.app'] = ABC,
  ['/Applications/Google Chrome.app'] = Pinyin,
  ['/Applications/Microsoft Edge.app'] = Pinyin,
  ['/Applications/Obsidian.app'] = Pinyin,
  ['/Applications/Microsoft To Do.app'] = Pinyin,
  ['/Applications/QQ.app'] = Pinyin,
  ['/Applications/WeChat.app'] = Pinyin,
  ['/Applications/企业微信.app'] = Pinyin,
  ['/Applications/DingTalk.app'] = Pinyin,
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
