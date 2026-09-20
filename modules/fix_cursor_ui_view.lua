-- ===================================================
-- 【后台守护】定时重置 CursorUIViewService（Apple 系统进程）
--
-- 处理什么问题：
--   CursorUIViewService 是 macOS 自带的文本输入光标 UI 服务
--   （/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/...
--    /CursorUIViewService.xpc），负责输入法/文本插入时的光标 UI。
--   它与 Cursor 编辑器无关，只是名字恰好带 "Cursor"。
--   macOS 存在已知 bug：该进程会持续内存泄漏（可涨到数 GB），
--   导致内存吃紧、输入法/文本 UI 卡顿异常。
--
-- 处理方式：
--   每小时用 pgrep -ix 找到进程并 kill -9，
--   系统会自动重建该服务，内存归零，输入无感知。
--   注意：无条件查杀，不做内存阈值判断。
-- ===================================================

local PROCESS_NAME = 'CursorUIViewService'
-- 检查间隔（秒），每 1 小时一次
local CHECK_INTERVAL = 3600

-- pgrep 可能返回多行（多个 PID），逐个强杀
local function killAllPids(stdOut)
  for pid in stdOut:gmatch('%d+') do
    hs.task.new('/bin/kill', nil, { '-9', pid }):start()
  end
end

local function autoKillLeakingCursorService()
  -- 1. 使用 pgrep 按进程名精确查找（-x 避免误匹配命令行文本，-i 兼容大小写）
  -- （exitCode 0 = 找到了）
  hs.task.new('/usr/bin/pgrep', function(exitCode, stdOut)
    if exitCode == 0 and stdOut and stdOut ~= '' then
      -- 2. 强制杀掉该进程（系统会自动秒速重建它，实现内存清零）
      killAllPids(stdOut)
      print('[Hammerspoon] 已成功自动重置 ' .. PROCESS_NAME .. ' 进程')
    end
  end, { '-ix', PROCESS_NAME }):start()
end

hs.timer.doEvery(CHECK_INTERVAL, autoKillLeakingCursorService)

-- 加载时先执行一次，启动即守护
autoKillLeakingCursorService()
