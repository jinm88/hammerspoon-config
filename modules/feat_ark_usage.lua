-- 方舟（arkcli）大模型订阅用量状态栏图标
--
-- 每分钟异步调用 `arkcli usage plan`：
--   状态栏纯文本显示 5 小时窗口用量百分比与距重置倒计时，如「32% · 1h54m」
--   下拉菜单三栏（Menlo 等宽对齐）：
--     第一栏：各周期使用百分比（整数）与多久后重置
--     第二栏：各周期总量与套餐档位
--     第三栏：刷新（位于 5h 行）
-- 也支持多订阅（personal + team）时按周期聚合显示。

local log = hs.logger.new('arkusage', 'warning')

local REFRESH_INTERVAL = 60 -- 秒；既是接口轮询间隔，也是倒计时走字间隔
local ARKCLI = hs.fs.pathToAbsolute('~/.npm-global/bin/arkcli') or '/Users/jin/.npm-global/bin/arkcli'

-- GUI 启动的 Hammerspoon PATH 极简（通常只有 /usr/bin:/bin），而 arkcli 是
-- #!/usr/bin/env node 脚本，需把 node 所在目录补进去，否则 task 直接 127
local NODE_BIN = hs.fs.pathToAbsolute('~/.local/bin') or '/Users/jin/.local/bin'
local TASK_ENV = { PATH = NODE_BIN .. ':/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin', HOME = os.getenv('HOME') }

-- 周期展示名：全部用 ASCII，配合 Menlo 等宽字体做列对齐
-- （中文宽字符在等宽字体下不是整数倍 ASCII 宽，无法用空格精确对齐）
local PERIOD_LABELS = {
  ['5h'] = '5h',
  weekly = 'Week',
  monthly = 'Month',
  daily = 'Day',
}

-- 菜单行顺序；第一行即状态栏主显示周期（第三栏刷新挂在这一行）
local PERIOD_ORDER = { '5h', 'daily', 'weekly', 'monthly' }
local PRIMARY_LABEL = '5h'

-- 本机本地时区相对 UTC 的偏移秒数（东八区为 +28800），用于正确解析带偏移的 ISO 时间
do
  local now = os.time()
  LOCAL_UTC_OFFSET = os.difftime(now, os.time(os.date('!*t', now)))
end

local menubar = hs.menubar.new()
local lastData = nil    -- 最近一次解析成功的 items（含 periods）
local lastUpdated = nil -- 最近一次成功更新的 epoch
local loading = false
local refresh -- 前向声明，供菜单回调引用

-- 右侧补空格到长度 width（仅用于 ASCII 文本）
local function padEnd(s, width)
  s = tostring(s)
  return #s < width and (s .. string.rep(' ', width - #s)) or s
end

-- 左侧补空格
local function padStart(s, width)
  s = tostring(s)
  return #s < width and (string.rep(' ', width - #s) .. s) or s
end

-- 千分位；整数不带小数，非整数保留一位：61544.24 -> 61,544.2，10000 -> 10,000
local function formatNumber(n)
  if n == nil then return '?' end
  local s = (math.floor(n) == n) and tostring(math.floor(n)) or string.format('%.1f', n)
  local int, frac = s:match('^([^.]*)(%.?%d*)$')
  for _ = 1, 10 do
    local k
    int, k = int:gsub('^(-?%d+)(%d%d%d)', '%1,%2')
    if k == 0 then break end
  end
  return int .. (frac or '')
end

-- 紧凑数字：10,000 -> 10K，1,500 -> 1.5K，2,000,000 -> 2M
local function formatCompact(n)
  if n == nil then return '?' end
  local function trim(v)
    return (math.floor(v) == v) and tostring(math.floor(v)) or string.format('%.1f', v)
  end
  local abs = math.abs(n)
  if abs >= 1e6 then return trim(n / 1e6) .. 'M' end
  if abs >= 1e3 then return trim(n / 1e3) .. 'K' end
  return trim(n)
end

-- 带时区偏移的 ISO8601（2026-10-11T14:24:27+08:00）转 epoch
local function isoToEpoch(iso)
  if not iso then return nil end
  local y, mo, d, h, mi, s, zsign, zh, zm =
    iso:match('(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)([+-])(%d+):?(%d?)')
  if not y then return nil end
  local t = os.time({ year = y + 0, month = mo + 0, day = d + 0, hour = h + 0, min = mi + 0, sec = s + 0 })
  local zOff = (zh + 0) * 3600 + (zm + 0) * 60
  if zsign == '-' then zOff = -zOff end
  return t - zOff + LOCAL_UTC_OFFSET
end

-- 状态栏短倒计时：满 1 小时只显示整小时（1h），不足 1 小时显示分钟（43m）
local function formatRemainingShort(sec)
  if sec < 0 then return nil end
  local totalMin = math.floor(sec / 60)
  if totalMin < 60 then return string.format('%dm', totalMin) end
  return string.format('%dh', math.floor(totalMin / 60))
end

-- 秒数转紧凑倒计时：2h05m / 43m / 3d12h；过期返回 '--'
local function formatRemaining(sec)
  if sec < 0 then return '--' end
  local totalMin = math.floor(sec / 60)
  if totalMin < 60 then
    return string.format('%dm', totalMin)
  end
  local h = math.floor(totalMin / 60)
  if h < 24 then
    return string.format('%dh%02dm', h, totalMin % 60)
  end
  return string.format('%dd%02dh', math.floor(h / 24), h % 24)
end

-- 从所有订阅条目中收集周期数据；同一 label 出现多次（如个人版 + 团队版）时用量相加
local function collectPeriods(items)
  local byLabel = {}
  for _, item in ipairs(items or {}) do
    for _, p in ipairs(item.periods or {}) do
      local agg = byLabel[p.label]
      if not agg then
        agg = { label = p.label, used = 0, total = 0, resetEpoch = nil, tiers = {} }
        byLabel[p.label] = agg
      end
      agg.used = agg.used + (p.used or 0)
      agg.total = agg.total + (p.total or 0)
      local tier = table.concat({ item.edition, item.tier }, ' ')
      if tier ~= ' ' and not hs.fnutils.contains(agg.tiers, tier) then
        table.insert(agg.tiers, tier)
      end
      -- 多订阅时取最早的重置时间
      local resetEpoch = isoToEpoch(p.reset_at)
      if resetEpoch and (not agg.resetEpoch or resetEpoch < agg.resetEpoch) then
        agg.resetEpoch = resetEpoch
      end
    end
  end
  local periods = {}
  for _, label in ipairs(PERIOD_ORDER) do
    if byLabel[label] then
      local p = byLabel[label]
      p.percent = p.total > 0 and (p.used / p.total * 100) or 0
      table.insert(periods, p)
    end
  end
  return periods
end

local function primaryPeriod()
  if not lastData then return nil end
  for _, p in ipairs(collectPeriods(lastData)) do
    if p.label == PRIMARY_LABEL then return p end
  end
end

-- 菜单统一字体；不指定 color，文字跟随系统菜单的正常颜色（自动适配深浅色模式）
local MENU_FONT = { name = 'Menlo', size = 13 }
-- 列宽（显示宽度）
local COL_LABEL, COL_PCT, COL_REMAIN, COL_TOTAL = 5, 4, 6, 5

local function updateMenubar()
  local p = primaryPeriod()
  if not p then
    menubar:setTitle(loading and '··' or '—')
    return
  end
  -- 状态栏：百分比 + 短倒计时（36%·1h，不足 1 小时显示分钟）
  local pct = math.floor(p.percent + 0.5)
  local remain = p.resetEpoch and formatRemainingShort(p.resetEpoch - os.time())
  menubar:setTitle(remain and string.format('%d%%·%s', pct, remain) or pct .. '%')
end

-- 第一栏：周期名 + 整数百分比 + 倒计时
local function columnOne(p)
  local remain = p.resetEpoch and formatRemaining(p.resetEpoch - os.time()) or '--'
  local pct = math.floor(p.percent + 0.5) .. '%'
  return padEnd(PERIOD_LABELS[p.label] or p.label, COL_LABEL) .. '   '
    .. padStart(pct, COL_PCT) .. '   ' .. padEnd(remain, COL_REMAIN)
end

-- 第二栏：总量（紧凑格式）
local function columnTwo(p)
  return padStart(formatCompact(p.total), COL_TOTAL)
end

local function buildMenu()
  local menu = {}

  if loading and not lastData then
    table.insert(menu, { title = '正在更新…', disabled = true })
  end

  if lastData then
    for _, p in ipairs(collectPeriods(lastData)) do
      table.insert(menu, {
        title = hs.styledtext.new(columnOne(p) .. '   ' .. columnTwo(p), { font = MENU_FONT }),
        tooltip = string.format('已用 %.1f%%（%s / %s）\n重置时间 %s',
          p.percent, formatNumber(p.used), formatNumber(p.total),
          p.resetEpoch and os.date('%m-%d %H:%M', p.resetEpoch) or '?'),
        -- 不能设 disabled（macOS 会把文字变灰）；给空 fn 保持正常文字颜色且可高亮
        fn = function() end,
      })
    end

    -- 套餐档位（去重）
    local tiers = {}
    for _, item in ipairs(lastData) do
      local tier = table.concat({ item.edition, item.tier }, ' '):gsub('^%s+', '')
      if tier ~= '' and not hs.fnutils.contains(tiers, tier) then
        table.insert(tiers, tier)
      end
    end
    table.insert(menu, { title = '-' })
    table.insert(menu, { title = table.concat(tiers, ', '), fn = function() end })
  elseif not loading then
    table.insert(menu, { title = '用量获取失败', fn = function() end })
  end

  table.insert(menu, { title = '刷新', fn = function() refresh() end })
  return menu
end

-- hs.task 回调：stdout -> JSON -> 更新 UI
local function onExit(code, stdout, stderr)
  loading = false
  if code ~= 0 then
    log.wf('arkcli 退出码 %d: %s', code, stderr or '')
    updateMenubar()
    return
  end
  local ok, data = pcall(hs.json.decode, stdout)
  if not ok or type(data) ~= 'table' or not data.items then
    log.w('arkcli 输出解析失败：' .. (stdout or ''):sub(1, 200))
    updateMenubar()
    return
  end
  lastData = data.items
  lastUpdated = os.time()
  updateMenubar()
end

-- 异步查询，绝不阻塞 Hammerspoon 主线程
refresh = function()
  if loading then return end
  loading = true
  if not lastData then updateMenubar() end
  local task = hs.task.new(ARKCLI, onExit, { 'usage', 'plan' })
  task:setEnvironment(TASK_ENV)
  task:start()
end

menubar:setMenu(buildMenu)
menubar:setTooltip('方舟大模型订阅用量（arkcli）')

-- 每分钟：先走倒计时（纯本地），再拉接口
ark_usage_timer = hs.timer.doEvery(REFRESH_INTERVAL, function()
  updateMenubar()
  refresh()
end)
refresh()
