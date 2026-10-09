-- **************************************************
-- 键盘类型判断与自动监听
--
-- 枚举当前 HID 键盘：
-- - 存在外接键盘：右侧修饰键使用 rCtrl
-- - 只有 Mac 内置键盘：右侧修饰键使用 rOpt
--
-- 后台定时检测，USB / 蓝牙键盘连接或断开后自动通知订阅者。
-- **************************************************

local M = {}

local POLL_INTERVAL = 300
local listeners = {}

local function detectRightModifier()
  -- hidutil list keyboard 会列出 Services / Devices 中的键盘相关 HID 条目。
  -- 只解析 Services，且只认 Generic Desktop(1) / Keyboard(6)，
  -- 排除触控板、虚拟鼠标，以及 Devices 中的重复驱动条目。
  local output = hs.execute('hidutil list keyboard')
  local hasBuiltInKeyboard = false
  local hasExternalKeyboard = false
  local inServicesSection = false

  for line in (output or ''):gmatch('[^\r\n]+') do
    if line == 'Services:' then
      inServicesSection = true
    elseif line == 'Devices:' then
      break
    elseif inServicesSection then
      local tokens = {}
      for token in line:gmatch('%S+') do
        table.insert(tokens, token)
      end

      -- 列：VendorID ProductID LocationID UsagePage Usage ... Built-In
      if #tokens >= 9 and tokens[4] == '1' and tokens[5] == '6' then
        if tokens[#tokens] == '1' then
          hasBuiltInKeyboard = true
        else
          -- UniversalControl 等虚拟键盘不是物理外接键盘，不参与判断
          if not line:find('UniversalControl') then
            hasExternalKeyboard = true
          end
        end
      end
    end
  end

  if hasExternalKeyboard or not hasBuiltInKeyboard then
    return 'rCtrl'
  end

  return 'rOpt'
end

function M.subscribe(callback)
  table.insert(listeners, callback)
end

local function refresh()
  local newModifier = detectRightModifier()
  if newModifier == M.rightModifier then return end

  local oldModifier = M.rightModifier
  M.rightModifier = newModifier
  M.isNativeMacKeyboard = newModifier == 'rOpt'

  for _, callback in ipairs(listeners) do
    local ok, err = pcall(callback, newModifier, oldModifier)
    if not ok then
      hs.logger.new('keyboard_profile', 'error').e('键盘切换回调失败: ' .. tostring(err))
    end
  end
end

M.rightModifier = detectRightModifier()
M.isNativeMacKeyboard = M.rightModifier == 'rOpt'
M.refresh = refresh

-- 全局引用，防止 timer 被 GC
keyboard_profile_timer = hs.timer.doEvery(POLL_INTERVAL, refresh)

return M
