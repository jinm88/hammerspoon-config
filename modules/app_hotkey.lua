-- 修饰键
local MODS = { 'rCmd' }
-- 映射
local APP_MAPPING = {
  a = 'Safari',             -- rCmd + A 打开 Safari
  s = 'Slack',              -- rCmd + S 打开 Slack
  d = 'iTerm',              -- rCmd + D 打开 iTerm (或 'Terminal')
  f = 'Finder',             -- rCmd + F 打开 Finder
  c = 'Visual Studio Code', -- rCmd + C 打开 VS Code
  n = 'Notion',             -- rCmd + N 打开 Notion
  o = 'Obsidian',           -- rCmd + O 打开 Obsidian
  w = 'WeChat',             -- rCmd + W 打开微信
  m = 'Mail',               -- rCmd + M 打开 Mail 应用
}
----------------------------------------------------

hs.loadSpoon('LeftRightHotkey')

-- 4. 绑定热键逻辑
for key, appName in pairs(APP_MAPPING) do
  -- 定义热键处理函数
  local launchHandler = function()
    -- 使用 hs.application.launchOrFocus() 函数：
    -- 如果应用未运行，则启动它；如果已运行，则切换焦点到该应用。
    local app = hs.application.launchOrFocus(appName)

    -- 如果应用未找到或启动失败，发出通知
    if not app then
      hs.notify.show('Hammerspoon', '应用启动失败', '未找到应用或启动失败: ' .. appName, 'Beep')
    end
  end

  -- 使用 LeftRightHotkey:bind 进行绑定。
  -- 我们将启动逻辑放在 pressedFn (按下时执行)，
  -- 释放和点击函数设置为 nil，以实现最快的响应速度。
  spoon.LeftRightHotkey:bind(MODS, key, launchHandler, nil, nil)
end

-- 5. 启动 LeftRightHotkey 监听
spoon.LeftRightHotkey:start()