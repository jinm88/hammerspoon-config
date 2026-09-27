-- ===================================================
-- 蓝牙麦克风锁屏自动断开
--
-- 触发条件：
--   锁屏（screensDidLock）后持续 LOCK_SECONDS（10 分钟）仍未解锁
--   → 断开麦克风
--   解锁（screensDidUnlock）→ 取消倒计时；若麦克风是本模块断开的则自动重连
--
-- 说明：锁屏后若机器进入睡眠，定时器随系统暂停，唤醒（仍锁屏）后继续，
--       累计"锁屏且唤醒"满 10 分钟才断开。
--
-- 依赖：blueutil（brew 安装，/opt/homebrew/bin/blueutil）
-- 注意：用 hs.task（NSTask）调用；需在系统设置中授予 Hammerspoon 蓝牙权限
-- ===================================================

local BLUEUTIL = '/opt/homebrew/bin/blueutil'
local MIC_ADDR = '88-29-85-1b-97-75' -- DJI Mic Mini-1B9775
local LOCK_SECONDS = 10 * 60 -- 锁屏后多久断开

local logger = hs.logger.new('bt_mic', 'info')

-- 全局引用防 GC
bt_mic_lock_timer = nil           -- 锁屏倒计时
bt_mic_disconnected_by_us = false -- 麦克风是否由本模块断开（决定解锁时是否重连）

-- 异步执行 blueutil；onExit(code, stdout, stderr) 可选
local function runBlueutil(args, onExit)
  local t = hs.task.new(BLUEUTIL, function(code, stdout, stderr)
    if code ~= 0 then
      logger.e('blueutil ' .. table.concat(args, ' ') .. ' 失败(' .. tostring(code) .. '): ' .. tostring(stderr))
    end
    if onExit then onExit(code, stdout, stderr) end
  end, args)
  t:start()
  return t
end

-- 查询麦克风是否已连接（异步回调 connected: boolean）
local function checkConnected(cb)
  runBlueutil({ '--info', MIC_ADDR, '--format', 'json' }, function(code, stdout)
    local connected = code == 0
      and stdout ~= nil
      and stdout:gsub('%s+', ''):find('"connected":true') ~= nil
    cb(connected)
  end)
end

local function disconnectMic()
  checkConnected(function(connected)
    if not connected then return end
    logger.i('断开蓝牙麦克风 ' .. MIC_ADDR)
    runBlueutil({ '--disconnect', MIC_ADDR })
    bt_mic_disconnected_by_us = true
  end)
end

local function reconnectMic()
  if not bt_mic_disconnected_by_us then return end
  bt_mic_disconnected_by_us = false
  checkConnected(function(connected)
    if connected then return end
    logger.i('重连蓝牙麦克风 ' .. MIC_ADDR)
    runBlueutil({ '--connect', MIC_ADDR })
  end)
end

-- 开始锁屏倒计时：到点若仍锁屏则断开
local function scheduleDisconnect()
  if bt_mic_lock_timer then bt_mic_lock_timer:stop() end
  bt_mic_lock_timer = hs.timer.doAfter(LOCK_SECONDS, disconnectMic)
end

local function cancelScheduledDisconnect()
  if bt_mic_lock_timer then
    bt_mic_lock_timer:stop()
    bt_mic_lock_timer = nil
  end
end

bt_mic_watcher = hs.caffeinate.watcher.new(function(event)
  if event == hs.caffeinate.watcher.screensDidLock then
    -- 锁屏：10 分钟后断开
    scheduleDisconnect()
  elseif event == hs.caffeinate.watcher.screensDidUnlock then
    -- 解锁：取消倒计时并按需重连
    cancelScheduledDisconnect()
    reconnectMic()
  end
end)
bt_mic_watcher:start()
