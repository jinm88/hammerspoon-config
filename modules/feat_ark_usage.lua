-- 方舟（arkcli）大模型订阅用量状态栏图标
--
-- 每分钟异步调用 `arkcli usage plan`。该接口一次返回多个产品的订阅
-- （items[]：agent-plan / coding-plan，各产品又可能有 personal / team 版），
-- 不同产品的周期结构不同：
--   agent-plan ：5h / weekly / monthly，带 used/total/reset_at
--   coding-plan：session / weekly / monthly，多数周期只给 percent
-- 因此菜单按「产品」分组展示；同一产品若有多个订阅（personal+team），
-- 数值型用量相加、重置时间取最早，百分比型取最大值。
--
-- 状态栏默认显示 agent-plan（其主周期为滚动 5h 窗口）；点击菜单中任意 plan 标题行
-- 即可切换状态栏显示哪个 plan（选择持久化到 hs.settings），周期固定取该 plan 的
-- 主周期（agent-plan=5h，coding-plan=session）。标题行最前预留一格状态位，
-- 当前状态栏显示的 plan 在该位标 ✓，其余留空对齐。
-- 例外：若所选 plan 的某个更长周期余量比主周期还少（长周期先见底，短周期的
-- 可用量实际被它封顶，数字没有意义），状态栏改为显示余量最少的长周期。
-- 余量比较一律用绝对余量（total-used，同 plan 单位一致）；只给 percent、
-- 没有具体数值的周期无法换算成量，不参与比较（coding-plan 因此不触发该切换）。
-- 菜单中被长周期「压住」的短周期行不隐藏，用系统禁用态（disabled）显示：
-- macOS 自动置灰且不可选中。
--
-- 菜单行（Menlo 等宽对齐）每行依次为：倒计时（5h/session 显示 时:分；周/月满 1 天
-- 显示剩余天数如 12d，不足 1 天同样显示 时:分）、整数剩余百分比（向上取整避免 0%）、周期名。
-- （使用量和已用/总量数值不占列，只在各行 tooltip 中展示）

local log = hs.logger.new('arkusage', 'warning')

local REFRESH_INTERVAL = 60 -- 秒；既是接口轮询间隔，也是倒计时走字间隔
local ARKCLI = hs.fs.pathToAbsolute('~/.npm-global/bin/arkcli') or '/Users/jin/.npm-global/bin/arkcli'

-- GUI 启动的 Hammerspoon PATH 极简（通常只有 /usr/bin:/bin），而 arkcli 是
-- #!/usr/bin/env node 脚本，需把 node 所在目录补进去，否则 task 直接 127。
-- hs.execute 第二参数 true = 在用户登录 shell 环境中执行（加载 ~/.zprofile 等，
-- 拿到真实 PATH），直接让 shell 告诉我们 node 在哪，不用猜候选目录。
-- 仅在模块加载时执行一次的同步调用，登录 shell 启动开销可忽略。
local NODE_BIN do
  local out, ok = hs.execute('command -v node', true)
  -- 取输出的最后一行，防登录 shell 的 rc 文件打印杂项内容污染
  local path = ok and out and out:gsub('%s+$', ''):match('([^\n]+)$')
  if path and path:sub(1, 1) == '/' and hs.fs.attributes(path, 'mode') then
    NODE_BIN = path:match('^(.*)/[^/]+$')
  else
    NODE_BIN = '/usr/local/bin' -- 查询失败兜底
  end
end
local TASK_ENV = {
  PATH = table.concat({ NODE_BIN, '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin' }, ':'),
  HOME = os.getenv('HOME'),
}

-- 产品展示名
local PRODUCT_NAMES = {
  ['agent-plan'] = 'Agent Plan',
  ['coding-plan'] = 'Coding Plan',
  ['agent-plan-team'] = 'Agent Plan (Team)',
  ['coding-plan-team'] = 'Coding Plan (Team)',
}

-- 周期展示名：全部用 ASCII，配合 Menlo 等宽字体做列对齐
-- （中文宽字符在等宽字体下不是整数倍 ASCII 宽，无法用空格精确对齐）
local PERIOD_LABELS = {
  ['session'] = 'Sess',
  ['5h'] = '5h',
  weekly = 'Week',
  monthly = 'Month',
  daily = 'Day',
}

-- 菜单行顺序；状态栏默认显示的 plan 见 PRIMARY_PRODUCT，其主周期见 PRIMARY_LABELS
local PERIOD_ORDER = { 'session', '5h', 'daily', 'weekly', 'monthly' }
-- 周期长短排名（下标即长短序），用于判断某周期是否比主周期更长
local PERIOD_RANK = {}
for i, label in ipairs(PERIOD_ORDER) do PERIOD_RANK[label] = i end
local PRIMARY_PRODUCT = 'agent-plan'

-- 本机本地时区相对 UTC 的偏移秒数（东八区为 +28800），用于正确解析带偏移的 ISO 时间
do
  local now = os.time()
  LOCAL_UTC_OFFSET = os.difftime(now, os.time(os.date('!*t', now)))
end

local SETTINGS_KEY = 'arkUsagePlan' -- hs.settings 中保存选中 plan product id 的键名

local menubar = hs.menubar.new()
local lastData = nil    -- 最近一次解析成功的「产品分组」数组
local lastUpdated = nil -- 最近一次成功更新的 epoch
local loading = false
local refresh -- 前向声明，供菜单回调引用

-- 用户选定的状态栏 plan（product id，如 coding-plan）；nil 表示默认（agent-plan）
local currentProduct = hs.settings.get(SETTINGS_KEY)
if type(currentProduct) ~= 'string' then currentProduct = nil end

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

-- 带时区偏移的 ISO8601（2026-10-11T14:24:27+08:00）转 epoch
local function isoToEpoch(iso)
  if not iso then return nil end
  local y, mo, d, h, mi, s, zsign, zh, zm =
    iso:match('(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)([+-])(%d+):?(%d*)')
  if not y then return nil end
  local t = os.time({ year = y + 0, month = mo + 0, day = d + 0, hour = h + 0, min = mi + 0, sec = s + 0 })
  local zOff = (zh + 0) * 3600 + (zm + 0) * 60
  if zsign == '-' then zOff = -zOff end
  return t - zOff + LOCAL_UTC_OFFSET
end

-- 状态栏短倒计时：满 1 天显示天数（12d）；满 1 小时只显示整小时（1h），
-- 不足 1 小时显示分钟（43m）
local function formatRemainingShort(sec)
  if sec < 0 then return nil end
  if sec >= 86400 then return string.format('%dd', math.floor(sec / 86400)) end
  local totalMin = math.floor(sec / 60)
  if totalMin < 60 then return string.format('%dm', totalMin) end
  return string.format('%dh', math.floor(totalMin / 60))
end

-- 滚动窗口（5h/session）倒计时：时:分（如 4:39）；过期返回 '--'
local function formatRemainingHM(sec)
  if sec < 0 then return '--' end
  return string.format('%d:%02d', math.floor(sec / 3600), math.floor((sec % 3600) / 60))
end

-- 周/月长周期倒计时：满 1 天只显示天数（12d）；不足 1 天与滚动窗口一样显示 时:分（23:05）
local function formatRemainingDays(sec)
  if sec < 0 then return '--' end
  if sec < 24 * 3600 then return formatRemainingHM(sec) end
  return string.format('%dd', math.floor(sec / 86400))
end

-- 把接口 items[] 按产品聚合成分组数组：
--   { product, name, tiers={...}, periods={ label, used, total, percent, resetEpoch, numeric } }
-- 同一产品的多个订阅（personal/team）：
--   数值型 used/total 相加、重置时间取最早；只有 percent 的周期取百分比最大值。
local function groupItems(items)
  local groups = {}
  local order = {}
  for _, item in ipairs(items or {}) do
    if item.subscribed then
      local product = item.product or 'unknown'
      local g = groups[product]
      if not g then
        g = { product = product, name = PRODUCT_NAMES[product] or product, tiers = {}, byLabel = {} }
        groups[product] = g
        table.insert(order, g)
      end
      -- 档位描述：coding-plan 无 tier 字段，只写 edition；team 产品自身已含 team 语义
      local tier = item.tier and table.concat({ item.edition, item.tier }, ' ') or (item.edition or '')
      if tier ~= '' and not hs.fnutils.contains(g.tiers, tier) then
        table.insert(g.tiers, tier)
      end
      for _, p in ipairs(item.periods or {}) do
        local agg = g.byLabel[p.label]
        if not agg then
          agg = {
            label = p.label, used = 0, total = 0, hasNumbers = false,
            percentOnly = nil, resetEpoch = nil,
          }
          g.byLabel[p.label] = agg
        end
        if type(p.used) == 'number' or type(p.total) == 'number' then
          agg.hasNumbers = true
          agg.used = agg.used + (p.used or 0)
          agg.total = agg.total + (p.total or 0)
        elseif type(p.percent) == 'number' then
          -- 只有百分比的周期（如 coding-plan session/weekly/monthly）
          if not agg.percentOnly or p.percent > agg.percentOnly then
            agg.percentOnly = p.percent
          end
        end
        local resetEpoch = isoToEpoch(p.reset_at)
        if resetEpoch and (not agg.resetEpoch or resetEpoch < agg.resetEpoch) then
          agg.resetEpoch = resetEpoch
        end
      end
    end
  end

  for _, g in ipairs(order) do
    g.periods = {}
    for _, label in ipairs(PERIOD_ORDER) do
      local agg = g.byLabel[label]
      if agg then
        if agg.hasNumbers and agg.total > 0 then
          agg.percent = agg.used / agg.total * 100
        else
          agg.percent = agg.percentOnly or 0
        end
        agg.numeric = agg.hasNumbers and agg.total > 0
        table.insert(g.periods, agg)
      end
    end
  end
  return order
end

-- 各 plan 在状态栏中展示的主周期（取该 plan 在 PERIOD_ORDER 中最靠前的可用周期）；
-- agent-plan 主周期为滚动 5h 窗口，coding-plan 为 session
local PRIMARY_LABELS = {
  ['agent-plan'] = '5h',
  ['coding-plan'] = 'session',
  ['agent-plan-team'] = '5h',
  ['coding-plan-team'] = 'session',
}

-- 在分组中查找指定产品
local function findGroup(product)
  for _, g in ipairs(lastData or {}) do
    if g.product == product then return g end
  end
end

-- 取一个 plan 的状态栏主周期：优先 PRIMARY_LABELS 配置，否则取第一个可用周期
local function primaryOf(g)
  if not g or #g.periods == 0 then return nil end
  local preferred = PRIMARY_LABELS[g.product]
  if preferred then
    for _, p in ipairs(g.periods) do
      if p.label == preferred then return p end
    end
  end
  return g.periods[1]
end

-- 状态栏当前 plan/周期：用户选择的 plan > 默认（agent-plan）> 第一个 plan；
-- 返回所属分组 g 与周期 p（g 用于菜单打勾）
local function resolvePrimary()
  if not lastData then return nil end
  local g, p
  if currentProduct then g = findGroup(currentProduct) end
  if g then p = primaryOf(g) end
  if not p then
    g = findGroup(PRIMARY_PRODUCT)
    p = primaryOf(g)
  end
  if not p and lastData[1] then
    g = lastData[1]
    p = primaryOf(g)
  end
  return g, p
end

-- 在 g 的各周期中，找出比 p 更长且绝对余量（total-used）比 p 还少的周期里
-- 余量最少的一个（即瓶颈落在更长周期上，p 的可用量实际被它封顶）；无则返回 nil。
-- 只有双方都带具体数值才能比较；只给 percent 的周期无法换算成量，不参与比较
local function tighterLongerPeriod(g, p)
  if not p.numeric then return nil end
  local pRank = PERIOD_RANK[p.label] or 0
  local pAbs = p.total - p.used
  local best, bestAbs
  for _, q in ipairs(g.periods) do
    if q.numeric and (PERIOD_RANK[q.label] or 0) > pRank then
      local qAbs = q.total - q.used
      if qAbs < pAbs and (not bestAbs or qAbs < bestAbs) then
        best, bestAbs = q, qAbs
      end
    end
  end
  return best
end

-- 状态栏实际展示的周期：默认取主周期；若瓶颈在更长周期，则改为剩余最少的长周期
local function displayPeriod()
  local g, p = resolvePrimary()
  if not p then return nil end
  return tighterLongerPeriod(g, p) or p
end

-- 剩余百分比：状态栏与菜单行共用的唯一计算入口，保证两处永远一致；
-- 向上取整，余量未尽不显示 0%
local function remainingPercent(p)
  return math.ceil(100 - p.percent)
end

-- 菜单统一字体；不指定 color，文字跟随系统菜单的正常颜色（自动适配深浅色模式）
local MENU_FONT = { name = 'Menlo', size = 13 }
-- 列宽（显示宽度）：周期名 / 剩余时间 / 百分比
local COL_LABEL, COL_REMAIN, COL_PCT = 5, 6, 4

local function updateMenubar()
  local p = displayPeriod()
  if not p then
    menubar:setTitle(loading and '··' or '—')
    return
  end
  -- 状态栏：短倒计时 + 剩余百分比（4h·57%，不足 1 小时倒计时显示分钟）
  local pct = remainingPercent(p)
  local remain = p.resetEpoch and formatRemainingShort(p.resetEpoch - os.time())
  menubar:setTitle(remain and string.format('%s·%d%%', remain, pct) or pct .. '%')
end

-- 第一栏：倒计时 + 整数百分比
local function columnOne(p)
  -- 周/月满 1 天显示剩余天数，不足 1 天与 5h/session 一样显示 时:分
  local fmt = (p.label == 'weekly' or p.label == 'monthly') and formatRemainingDays or formatRemainingHM
  local remain = p.resetEpoch and fmt(p.resetEpoch - os.time()) or '--'
  local pct = remainingPercent(p) .. '%'
  -- 倒计时、百分比均右对齐
  return padStart(remain, COL_REMAIN) .. '   ' .. padStart(pct, COL_PCT)
end

-- 第二栏：周期名
local function columnTwo(p)
  return padEnd(PERIOD_LABELS[p.label] or p.label, COL_LABEL)
end

local function buildMenu()
  local menu = {}

  if loading and not lastData then
    table.insert(menu, { title = '正在更新…', disabled = true })
  end

  -- 当前状态栏显示的 plan（用于标题行打勾）
  local selG = resolvePrimary()

  if lastData then
    for gi, g in ipairs(lastData) do
      if gi > 1 then table.insert(menu, { title = '-' }) end
      -- plan 标题行：点击即把该 plan 设为状态栏显示；标题用系统默认字体、保持左对齐。
      -- 标题前预留一格状态位：当前显示在状态栏的 plan 标 ✓，其余以空格补齐，
      -- 保证各 plan 名称左对齐（普通文字，不占用菜单项左侧状态图标区，不会向左突出）
      local isSelected = selG == g
      local header = isSelected and '✓  ' or '    '
      header = header .. g.name
      if #g.tiers > 0 then header = header .. '  ·  ' .. table.concat(g.tiers, ', ') end
      table.insert(menu, {
        title = header,
        tooltip = isSelected and '当前显示在状态栏' or '点击在状态栏显示该 plan',
        fn = function()
          if g.product == PRIMARY_PRODUCT then
            currentProduct = nil
            hs.settings.clear(SETTINGS_KEY)
          else
            currentProduct = g.product
            hs.settings.set(SETTINGS_KEY, currentProduct)
          end
          updateMenubar()
        end,
      })

      for _, p in ipairs(g.periods) do
        local tooltip
        if p.numeric then
          tooltip = string.format('%s %s\n已用 %.1f%%（%s / %s）\n重置时间 %s',
            g.name, p.label, p.percent, formatNumber(p.used), formatNumber(p.total),
            p.resetEpoch and os.date('%m-%d %H:%M', p.resetEpoch) or '?')
        else
          tooltip = string.format('%s %s\n已用 %.1f%%\n重置时间 %s',
            g.name, p.label, p.percent,
            p.resetEpoch and os.date('%m-%d %H:%M', p.resetEpoch) or '?')
        end
        -- 瓶颈落在更长周期时，本周期行设为禁用态（macOS 自动置灰、不可选中）。
        -- 普通周期行不能设 disabled（不想变灰），给空 fn 保持正常文字颜色且可高亮
        local tighter = tighterLongerPeriod(g, p)
        table.insert(menu, {
          title = hs.styledtext.new(columnOne(p) .. '   ' .. columnTwo(p), { font = MENU_FONT }),
          tooltip = tooltip,
          disabled = tighter ~= nil,
          fn = function() end,
        })
      end
    end
  elseif not loading then
    table.insert(menu, { title = '用量获取失败', fn = function() end })
  end

  table.insert(menu, { title = '-' })
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
  lastData = groupItems(data.items)
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
