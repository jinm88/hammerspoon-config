-- **************************************************
-- RAPOO 蓝牙键盘右 Control → 苹果 Fn 键的设备级映射持久化
--
-- 背景：
-- hidutil UserKeyMapping 是内核 HID 层的静态查表，重启 Mac 或蓝牙
-- 重连后丢失，需要重新下发。本模块轮询 RAPOO 是否在线，在线且映射
-- 缺失时自动补写。
--
-- 映射（2026-11 实测，见 docs/agents 或 git 历史）：
--   源：右 Control，HID usage 0x07/0xE4 = 30064771300
--   目标：苹果 Fn/Globe，厂商页 0xFF usage 0x03 = 1095216660483
-- 注意：该目标 usage 在 RAPOO 上产出的是 keycode 36 + Help 标志位的
-- 混合事件（非规范 flagsChanged/63），但实测可唤起微信输入法语音；
-- 标准键映射（如 rCtrl→rCmd）在同设备上事件形态正常，说明 hidutil
-- 本身工作，差异来自苹果厂商码的驱动解释。
--
-- 仅作用于 RAPOO（VID 0x245a / PID 0x8276），不影响遥控器与其他键盘。
-- **************************************************

local M = {}

local POLL_INTERVAL = 60
local VENDOR_ID = 9306          -- 0x245a
local PRODUCT_ID = 33398        -- 0x8276
local MATCHING = '{"VendorID":' .. VENDOR_ID .. ',"ProductID":' .. PRODUCT_ID .. '}'
local SRC_USAGE = 30064771300   -- 右 Control 0x07/0xE4
local DST_USAGE = 1095216660483 -- 苹果 Fn 0xFF/0x03
local SET_PAYLOAD = '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":'
  .. SRC_USAGE .. ',"HIDKeyboardModifierMappingDst":' .. DST_USAGE .. '}]}'

local log = hs.logger.new('fn_key_remap', 'info')

-- RAPOO 是否在线：只解析 hidutil list keyboard 的 Services 段，
-- 与旧 keyboard_profile 的判定口径一致（排除 Devices 重复驱动条目）。
local function isRapooOnline()
  local output = hs.execute('hidutil list keyboard') or ''
  local inServices = false
  for line in output:gmatch('[^\r\n]+') do
    if line == 'Services:' then
      inServices = true
    elseif line == 'Devices:' then
      break
    elseif inServices and line:find('0x245a') and line:find('0x8276') then
      return true
    end
  end
  return false
end

-- 映射是否已存在：--get 输出中能读到目标 usage 即视为已生效
local function isMappingPresent()
  local cmd = 'hidutil property --matching \'' .. MATCHING .. '\' --get UserKeyMapping'
  local output = hs.execute(cmd) or ''
  return output:find(tostring(DST_USAGE), 1, true) ~= nil
end

local function applyMapping()
  local cmd = 'hidutil property --matching \'' .. MATCHING
    .. '\' --set \'' .. SET_PAYLOAD .. '\''
  local ok, _, rc = hs.execute(cmd)
  if rc == 0 then
    log.i('已下发 rCtrl→Fn 映射')
  else
    log.e('映射下发失败 rc=' .. tostring(rc))
  end
end

local function refresh()
  if not isRapooOnline() then return end
  if not isMappingPresent() then
    applyMapping()
  end
end

M.refresh = refresh
M.isRapooOnline = isRapooOnline
M.isMappingPresent = isMappingPresent

-- 启动后先跑一次，再进入轮询
refresh()
-- 全局引用，防止 timer 被 GC
fn_key_remap_timer = hs.timer.doEvery(POLL_INTERVAL, refresh)

return M
