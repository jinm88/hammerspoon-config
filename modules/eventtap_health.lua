-- ===================================================
-- EventTap 健康守护
--
-- 解决「快捷键偶尔完全失效、必须 Reload Config」的问题：
-- macOS 可能在以下时刻让 eventtap 停止投递事件，且部分状态下
-- tap 对象 :isEnabled() 仍返回 true（僵尸态），普通 watchdog 无法发现：
--   - 睡眠 / 唤醒
--   - 锁屏 / 解锁、切换用户、会话退出与恢复
--   - tap 回调阻塞触发系统超时后，C 层自动重启失败的少数情况
--
-- 策略：
--   1. 每 INTERVAL 秒检查 :isEnabled()，被系统禁用则立即 :start()
--   2. 唤醒、解锁、会话激活时，无条件 stop + 重建（工厂函数），治僵尸态
--   3. 每 RECREATE_INTERVAL 秒主动重建一次，作为兜底
--
-- 用法：
--   require('modules.eventtap_health').register(function()
--     local tap = hs.eventtap.new({...}, callback)
--     tap:start()
--     return tap
--   end, 'my_tap_name')
-- ===================================================

local INTERVAL = 2          -- 禁用检测周期（秒）
local RECREATE_INTERVAL = 1800 -- 主动重建周期（秒），30 分钟

local M = {}

local entries = {} -- { name, factory, tap }

-- 重建一个 entry：先尽力停掉旧 tap，再用工厂函数新建
local function recreate(entry)
  local old = entry.tap
  if old then
    pcall(function() old:stop() end)
  end
  local ok, tap = pcall(entry.factory)
  if ok and tap then
    entry.tap = tap
  else
    hs.logger.new('tap_health', 'error').e('重建失败 [' .. entry.name .. ']: ' .. tostring(tap))
  end
end

-- 注册一个 tap：factory 负责 new + start 并返回 tap 对象
function M.register(factory, name)
  local entry = { name = name or 'unnamed', factory = factory }
  entry.tap = factory()
  table.insert(entries, entry)
  return entry.tap
end

-- 用全局引用，防止被 GC
tap_health_timer = hs.timer.doEvery(INTERVAL, function()
  for _, entry in ipairs(entries) do
    local tap = entry.tap
    if not tap or not tap:isEnabled() then
      recreate(entry)
    end
  end
end)

tap_health_recreate_timer = hs.timer.doEvery(RECREATE_INTERVAL, function()
  for _, entry in ipairs(entries) do
    recreate(entry)
  end
end)

-- 系统电源事件（唤醒/睡眠）
tap_health_power_watcher = hs.caffeinate.watcher.new(function(event)
  if event == hs.caffeinate.watcher.systemDidWake
    or event == hs.caffeinate.watcher.screensDidUnlock
    or event == hs.caffeinate.watcher.sessionDidBecomeActive then
    -- 稍等片刻，等系统事件管线恢复
    hs.timer.doAfter(1, function()
      for _, entry in ipairs(entries) do
        recreate(entry)
      end
    end)
  end
end)
tap_health_power_watcher:start()

return M
