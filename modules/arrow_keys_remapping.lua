-- **************************************************
-- 方向键映射
-- **************************************************

-- --------------------------------------------------
-- 修饰键
local MODS = { 'lOpt' }

-- [按下键 (Source)] = [模拟的系统键 (Target)]
local MAPPING = {
  ['w'] = 'up',
  ['s'] = 'down',
  ['a'] = 'left',
  ['d'] = 'right',
  ['q'] = 'pageup',
  ['e'] = 'pagedown',
  ['r'] = 'home',
  ['f'] = 'end'
}
----------------------------------------------------

-- 加载 LeftRightHotkey 模块
hs.loadSpoon('LeftRightHotkey')

for sourceKey, targetKey in pairs(MAPPING) do
  -- 定义事件处理函数
  local handler = function()
    -- 模拟按下目标系统键 (例如 'up')
    hs.eventtap.event.newKeyEvent(hs.keycodes.map[targetKey], true):post()
    -- 模拟释放目标系统键
    hs.eventtap.event.newKeyEvent(hs.keycodes.map[targetKey], false):post()
  end

  -- 绑定热键：使用 MODS + sourceKey (例如 rCmd + w) 来触发 handler
  spoon.LeftRightHotkey:bind(MODS, sourceKey, handler, nil, handler)
end

-- 启动 LeftRightHotkey 监听
spoon.LeftRightHotkey:start()
