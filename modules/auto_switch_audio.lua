-- ===================================================
-- 音频输出自动校正
--
-- 目标：目标麦克风（DJI Mic Mini）连接时，macOS 可能把默认输出也切到它
--       （麦克风自身的输出端点通常听不到系统声音）。本模块保证：
--         默认输出落在黑名单设备上 → 自动切回上一个有效输出，
--         找不到上一个有效输出 → 兜底 Mac mini 内置扬声器。
--       输入设备一律不干预。
--
-- 与旧版差异：
--   1. 模块启动（含 Hammerspoon 开机启动）时立即校正一次，
--      不再把"启动时的当前输出"无条件记为有效设备；
--   2. 同时监听 dIn / dOut / dev# 三类事件，0.8s 防抖合并；
--   3. 有效输出 UID 持久化到 hs.settings，重启后仍可回切；
--   4. 黑名单按设备 UID（由蓝牙 MAC 派生，重命名设备不影响）匹配。
-- ===================================================

-- 黑名单输出设备 UID（目标麦克风的输出端点）
local BLACKLIST_UIDS = {
    ['88-29-85-1B-97-75:output'] = true, -- DJI Mic Mini-1B9775
}
local CHECK_DELAY = 0.8
local POLL_INTERVAL = 5 -- 秒：事件不可靠时的兜底轮询（实测编程式输出切换无任何 watcher 事件）
local FALLBACK_UID = 'BuiltInSpeakerDevice' -- Mac mini扬声器
local SETTINGS_KEY = 'autoSwitchAudio.lastValidOutputUID'

local logger = hs.logger.new('audio_watch', 'info')

-- 防抖句柄与轮询（全局引用防 GC）
audio_watch_timer = nil
audio_watch_poll = nil

-- 读取持久化的有效输出 UID
local function readStoredUID()
    local v = hs.settings.get(SETTINGS_KEY)
    return type(v) == 'string' and v or nil
end

-- 持久化有效输出 UID
local function storeUID(uid)
    if uid and uid ~= readStoredUID() then
        hs.settings.set(SETTINGS_KEY, uid)
    end
end

-- 选一个可回切的有效输出：持久化 UID → 内置扬声器 → nil
local function resolveBackup()
    local stored = readStoredUID()
    if stored and not BLACKLIST_UIDS[stored] then
        local dev = hs.audiodevice.findDeviceByUID(stored)
        if dev and dev:isOutputDevice() then
            return dev
        end
    end
    local fallback = hs.audiodevice.findDeviceByUID(FALLBACK_UID)
    if fallback and fallback:isOutputDevice() then
        return fallback
    end
    return nil
end

-- 校正一次：输出在黑名单上就切回，否则记住当前输出
local function reconcile()
    local current = hs.audiodevice.defaultOutputDevice()
    if not current then
        logger.w('无默认输出设备，跳过')
        return
    end

    if BLACKLIST_UIDS[current:uid()] then
        local backup = resolveBackup()
        if backup then
            local ok = backup:setDefaultOutputDevice()
            logger.i('输出被黑名单设备占用，切回: ' .. current:name() .. ' → ' .. backup:name() .. ' (' .. tostring(ok) .. ')')
            if ok then
                hs.alert.show('音频输出自动切回: ' .. backup:name())
            end
        else
            logger.e('黑名单设备占用输出，但找不到任何可回切设备')
        end
    else
        -- 当前输出正常，更新记忆（内存外持久化）
        storeUID(current:uid())
    end
end

-- 防抖：事件可能在短时间内成组到达（如蓝牙设备上线同时触发 dIn/dev#）
local function scheduleReconcile()
    if audio_watch_timer then
        audio_watch_timer:stop()
    end
    audio_watch_timer = hs.timer.doAfter(CHECK_DELAY, reconcile)
end

-- 启动即校正：覆盖"Hammerspoon 启动时输出已经错了"的场景
reconcile()

-- 事件监听负责快速响应（真实用户操作/系统切换通常仍有事件）
hs.audiodevice.watcher.setCallback(function(event)
    -- dIn （默认输入变化，4 字符带空格）/ dOut（默认输出变化）/ dev#（设备增减）
    if event == 'dIn ' or event == 'dOut' or event == 'dev#' then
        scheduleReconcile()
    end
end)
hs.audiodevice.watcher.start()

-- 兜底轮询：实测编程式（含部分系统路径）输出切换不产生任何 watcher 事件，
-- 只靠事件会漏掉静默切走；5 秒一次的轻量检查保证最终一致。
audio_watch_poll = hs.timer.doEvery(POLL_INTERVAL, reconcile)
