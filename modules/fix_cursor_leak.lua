-- ===================================================
-- 【后台守护】自动检测并清理卡死的 cursoruiviewservice
-- Cursor 的 UI 服务进程偶发内存泄漏/卡死，kill 后系统会自动重建，实现内存清零
-- ===================================================

local PROCESS_NAME = 'cursoruiviewservice'
-- 检查间隔（秒），每 1 小时一次
local CHECK_INTERVAL = 3600

-- pgrep 可能返回多行（多个 PID），逐个强杀
local function killAllPids(stdOut)
  for pid in stdOut:gmatch('%d+') do
    hs.task.new('/bin/kill', nil, { '-9', pid }):start()
  end
end

local function autoKillLeakingCursorService()
  -- 1. 使用 pgrep 查找该进程的 PID（exitCode 0 = 找到了）
  hs.task.new('/usr/bin/pgrep', function(exitCode, stdOut)
    if exitCode == 0 and stdOut and stdOut ~= '' then
      -- 2. 强制杀掉该进程（系统会自动秒速重建它，实现内存清零）
      killAllPids(stdOut)
      print('[Hammerspoon] 已成功自动重置卡死的 ' .. PROCESS_NAME .. ' 进程')
    end
  end, { '-f', PROCESS_NAME }):start()
end

hs.timer.doEvery(CHECK_INTERVAL, autoKillLeakingCursorService)

-- 加载时先执行一次，启动即守护
autoKillLeakingCursorService()
