-- **************************************************
-- 方向键映射
-- **************************************************

-- 应用列表格式 (类似 app_hotkey)
local KEY_LIST = {
  { mods = {'lOpt'}, key = 'w', target = 'up' },
  { mods = {'lOpt'}, key = 's', target = 'down' },
  { mods = {'lOpt'}, key = 'a', target = 'left' },
  { mods = {'lOpt'}, key = 'd', target = 'right' },
  { mods = {'lOpt'}, key = 'q', target = 'pageup', desc = 'PageUp' },
  { mods = {'lOpt'}, key = 'e', target = 'pagedown', desc = 'PageDown' },
  { mods = {'lOpt'}, key = 'r', target = 'home', desc = 'Home' },
  { mods = {'lOpt'}, key = 'f', target = 'end', desc = 'End' },
}

-- 导出配置
local M = { keyList = KEY_LIST }
----------------------------------------------------

-- 加载 LeftRightHotkey 模块
hs.loadSpoon('LeftRightHotkey')

for _, config in ipairs(M.keyList) do
  -- 定义事件处理函数
  local handler = function()
    -- 模拟按下目标系统键 (例如 'up')
    hs.eventtap.event.newKeyEvent(hs.keycodes.map[config.target], true):post()
    -- 模拟释放目标系统键
    hs.eventtap.event.newKeyEvent(hs.keycodes.map[config.target], false):post()
  end

  -- 绑定热键：使用 config.mods + config.key 来触发 handler
  spoon.LeftRightHotkey:bind(config.mods, config.key, handler, nil, handler)
end

-- 启动 LeftRightHotkey 监听
spoon.LeftRightHotkey:start()

return M
