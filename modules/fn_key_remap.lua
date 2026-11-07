-- **************************************************
-- 外接键盘右 Control → 苹果 Fn 键的设备级映射管理
--
-- 两部分职责：
-- 1. 枚举：从 `hidutil list keyboard --ndjson` 过滤出真正的键盘类
--    HID 服务（PrimaryUsagePage=1/PrimaryUsage=6），供命令面板
--    「FN键映射」选择目标设备。
-- 2. 持久化：用户选中的设备写入 hs.settings，轮询时对在线且在允许
--    清单内的设备自动补写 hidutil UserKeyMapping——重启 Mac 或蓝牙
--    重连后映射会丢失，需要重新下发。
--
-- 映射（2026-11 实测）：
--   源：右 Control，HID usage 0x07/0xE4 = 30064771300
--   目标：苹果 Fn/Globe，厂商页 0xFF usage 0x03 = 1095216660483
-- 该目标 usage 在 RAPOO 上产出 keycode 36 + Help 标志位的混合事件
-- （非规范 flagsChanged/63），但实测可唤起微信输入法语音；标准键
-- 映射（如 rCtrl→rCmd）在同设备上事件形态正常，说明 hidutil 本身
-- 工作，差异来自苹果厂商码的驱动解释。换新键盘后必须先实测再纳入。
--
-- 保护：苹果设备（触控板/内置键盘）与小米遥控器永不入列——遥控器
-- 的 F5→Fn 映射由 SayAll 管理，写第二张 UserKeyMapping 会冲突。
-- **************************************************

local M = {}

local POLL_INTERVAL = 60
local SETTINGS_KEY = 'fnKeyRemapTargets'

local SRC_USAGE = 30064771300   -- 右 Control 0x07/0xE4
local DST_USAGE = 1095216660483 -- 苹果 Fn 0xFF/0x03

-- 永不提供映射的设备
local APPLE_VID = 0x5AC
local REMOTE_VID = 0x2717
local REMOTE_PID = 0x32B8

-- 首次运行时的默认允许清单（历史已验证设备）
local DEFAULT_TARGETS = {
  { vid = 0x245A, pid = 0x8276, name = 'RAPOO Keyboard-2' },
}

local log = hs.logger.new('fn_key_remap', 'info')

-- ------------------------------------------------
-- 允许清单（hs.settings 持久化，不进 git）
-- ------------------------------------------------
local function loadTargets()
  -- 只按类型判断是否初始化：空表是用户移除全部设备后的合法状态，
  -- 不能再回退默认值（旧实现用 #saved>0 判断会把移除操作撤销）
  local saved = hs.settings.get(SETTINGS_KEY)
  if type(saved) == 'table' then return saved end
  hs.settings.set(SETTINGS_KEY, DEFAULT_TARGETS)
  return DEFAULT_TARGETS
end

local function saveTargets(targets)
  hs.settings.set(SETTINGS_KEY, targets)
end

function M.findTarget(vid, pid)
  for _, t in ipairs(loadTargets()) do
    if t.vid == vid and t.pid == pid then return t end
  end
  return nil
end

-- ------------------------------------------------
-- 设备枚举：只保留真正的键盘类 HID 服务
-- ------------------------------------------------
function M.listKeyboards()
  local json = require('hs.json')
  local output = hs.execute('hidutil list keyboard --ndjson') or ''
  local seen, result = {}, {}
  for line in output:gmatch('[^\r\n]+') do
    local ok, obj = pcall(json.decode, line)
    if ok
      and obj.type == 'service'
      and obj.PrimaryUsagePage == 1
      and obj.PrimaryUsage == 6
      and type(obj.VendorID) == 'number' and obj.VendorID ~= 0
      and obj.VendorID ~= APPLE_VID
      and not (obj.VendorID == REMOTE_VID and obj.ProductID == REMOTE_PID) then
      local key = obj.VendorID .. '/' .. obj.ProductID
      if not seen[key] then
        seen[key] = true
        table.insert(result, {
          vid = obj.VendorID,
          pid = obj.ProductID,
          name = (obj.Product and obj.Product ~= '') and obj.Product or ('未知设备 ' .. key),
        })
      end
    end
  end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end

-- ------------------------------------------------
-- 单设备映射操作
-- ------------------------------------------------
local function matching(vid, pid)
  return '{"VendorID":' .. vid .. ',"ProductID":' .. pid .. '}'
end

function M.isMappingPresent(vid, pid)
  local cmd = 'hidutil property --matching \'' .. matching(vid, pid) .. '\' --get UserKeyMapping'
  local output = hs.execute(cmd) or ''
  return output:find(tostring(DST_USAGE), 1, true) ~= nil
end

local function applyMapping(vid, pid)
  local payload = '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":'
    .. SRC_USAGE .. ',"HIDKeyboardModifierMappingDst":' .. DST_USAGE .. '}]}'
  local cmd = 'hidutil property --matching \'' .. matching(vid, pid)
    .. '\' --set \'' .. payload .. '\''
  -- hs.execute 返回 (output, success:boolean, exitType:string)，
  -- 第二返回值才是成功标志（本版本不是数字退出码）
  local _, ok = hs.execute(cmd)
  return ok == true
end

local function removeMapping(vid, pid)
  local cmd = 'hidutil property --matching \'' .. matching(vid, pid)
    .. '\' --set \'{"UserKeyMapping":[]}\''
  local _, ok = hs.execute(cmd)
  return ok == true
end

-- 面板动作：切换某设备的映射状态，并同步允许清单；返回切换后是否已映射
function M.toggleDevice(vid, pid, name)
  if M.findTarget(vid, pid) then
    if removeMapping(vid, pid) then
      local kept = {}
      for _, t in ipairs(loadTargets()) do
        if not (t.vid == vid and t.pid == pid) then table.insert(kept, t) end
      end
      saveTargets(kept)
      hs.alert.show('已移除映射：' .. name, { duration = 2 })
      return false
    end
    hs.alert.show('移除失败：' .. name, { duration = 2 })
    return true
  end
  if applyMapping(vid, pid) then
    local targets = loadTargets()
    table.insert(targets, { vid = vid, pid = pid, name = name })
    saveTargets(targets)
    hs.alert.show('已应用 rCtrl→Fn：' .. name, { duration = 2 })
    return true
  end
  hs.alert.show('映射下发失败：' .. name, { duration = 2 })
  return false
end

-- ------------------------------------------------
-- 轮询：允许清单内且在线的设备，映射缺失就补写
-- ------------------------------------------------
local function refresh()
  local online = {}
  for _, kb in ipairs(M.listKeyboards()) do
    online[kb.vid .. '/' .. kb.pid] = true
  end
  for _, t in ipairs(loadTargets()) do
    if online[t.vid .. '/' .. t.pid] and not M.isMappingPresent(t.vid, t.pid) then
      if applyMapping(t.vid, t.pid) then
        log.i('补写 rCtrl→Fn 映射: ' .. t.name)
      else
        log.e('映射补写失败: ' .. t.name)
      end
    end
  end
end

M.refresh = refresh

-- 启动后先跑一次，再进入轮询
refresh()
-- 全局引用，防止 timer 被 GC
fn_key_remap_timer = hs.timer.doEvery(POLL_INTERVAL, refresh)

return M
