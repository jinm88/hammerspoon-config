-- **************************************************
-- 方向键映射
-- **************************************************

-- --------------------------------------------------
-- 修饰键
local MODS = { 'rCtrl' }
-- 映射
local MAPPING = {
  up    = 'w',
  down  = 's',
  left  = 'a',
  right = 'd',
  pageup = 'r',
  pagedown = 'f',
  home = 'q',
  ['end'] = 'e'
}
----------------------------------------------------

hs.loadSpoon('LeftRightHotkey')

for targetKey, sourceKey in pairs(MAPPING) do
  local handler = function()
    hs.eventtap.event.newKeyEvent(hs.keycodes.map[targetKey], true):post()
    hs.eventtap.event.newKeyEvent(hs.keycodes.map[targetKey], false):post()
  end

  spoon.LeftRightHotkey:bind(MODS, sourceKey, handler, nil, handler)
end

spoon.LeftRightHotkey:start()
