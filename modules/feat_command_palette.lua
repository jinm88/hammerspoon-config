--[[
  类 Alfred 命令触发器（Command Palette）

  - 全局热键唤出搜索框（默认 ctrl+shift+space，见 CONFIG.hotkey），再次按下关闭
  - 自定义命令：register() 注册，支持子标题/图标/关键字带参数
  - 应用启动：输入应用名，Lua 过滤后回车启动或聚焦
  - 直达网址：输入 http(s):// 开头的内容，回车在默认浏览器打开
  - 关键字参数：「keyword 空格 参数」直接执行，例如 g hello → Google 搜索

  性能设计（针对 Hammerspoon 1.1.1 的 hs.chooser）：
  过滤完全在 Lua 完成（112 项约 0.04ms），每次只把少量匹配行交给 chooser，
  避免出现「单行 → 上百行」的表格重渲染（旧版原生重渲染会卡 ~200ms）。
  输入经小幅去抖后统一刷新。

  扩展示例：
    local palette = require('modules.feat_command_palette')
    palette.register(palette.makeShell('重启 Dock', 'killall Dock'))
    palette.register({
      text = '搜索',
      keyword = 'g',
      action = function(arg) hs.execute('open "https://www.google.com/search?q=' .. palette.urlEncode(arg) .. '"') end,
    })
]]

local CONFIG = {
  -- 唤出热键
  hotkey = { { 'ctrl', 'shift' }, 'space' },
  -- 唤出时临时切到该系统输入法（避免微信等第三方输入法在 chooser 里卡顿）；
  -- 面板关闭后自动切回原输入法。置为 nil 可关闭此行为。
  tempLayout = 'com.apple.keylayout.ABC',
  rows = 12,
  width = 36,
  -- 输入后多少秒刷新（等快速连敲完）
  refreshDelay = 0.06,
  -- 空查询时最多展示多少行（命令 + 部分应用）
  emptyLimit = 12,
  -- 有查询时最多展示多少匹配行
  matchLimit = 12,
}

------------------------------------------------------------
-- 命令注册表
------------------------------------------------------------
local commands = {}

local register, makeShell, makeOpen, urlEncode, chooser

--- 注册一条命令
-- @param cmd { text, subText?, image?, keyword?, action? , fn? }
function register(cmd)
  cmd.text = cmd.text or ''
  cmd.action = cmd.action or cmd.fn
  commands[cmd] = true
  return cmd
end

--- 便捷构造：执行 shell 命令
function makeShell(text, shell, opts)
  opts = opts or {}
  return {
    text = text,
    subText = opts.subText or shell,
    image = opts.image,
    keyword = opts.keyword,
    action = function()
      hs.execute(shell)
    end,
  }
end

--- 便捷构造：打开 URL（可带参数，%s 为参数占位）
function makeOpen(text, url, opts)
  opts = opts or {}
  return {
    text = text,
    subText = opts.subText or url,
    image = opts.image,
    keyword = opts.keyword,
    action = function(arg)
      local target = opts.baseUrl or url
      if arg and arg ~= '' then
        target = string.format(url, urlEncode(arg))
      elseif not opts.baseUrl then
        target = target:gsub('%%s', '')
      end
      hs.execute('open "' .. target .. '"')
    end,
  }
end

--- URL 编码（参数命令用）
function urlEncode(s)
  s = tostring(s or '')
  s = s:gsub('\n', '\r\n')
  s = s:gsub('([^%w%-%_%.%~])', function(c)
    return string.format('%%%02X', string.byte(c))
  end)
  return s
end

------------------------------------------------------------
-- 应用索引：mdfind 走 Spotlight 元数据，一次取全量并缓存
------------------------------------------------------------
local apps = nil
local appIconCache = {}

local function loadApps()
  local output = hs.execute(
    [[mdfind -onlyin /System/Applications -onlyin /Applications -onlyin "$HOME/Applications" \
      "kMDItemContentType == 'com.apple.application-bundle'" 2>/dev/null]]
  )
  local list = {}
  for path in string.gmatch(output or '', '[^\n]+') do
    local name = path:match('([^/]+)%.app$')
    if name then
      table.insert(list, { name = name, path = path })
    end
  end
  table.sort(list, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  apps = list
end

local function appIcon(path)
  local icon = appIconCache[path]
  if icon == nil then
    icon = hs.image.imageFromAppBundle(path) or false
    appIconCache[path] = icon
  end
  return icon or nil
end

------------------------------------------------------------
-- 动作透传：本版候选表只能放基础类型（函数会让整张表解析失败），
-- 动作放进 actionStore，候选里只存数字 id。
------------------------------------------------------------
local actionStore = {}

local function addAction(choices, row, fn)
  local id = #actionStore + 1
  actionStore[id] = fn
  row.__id = id
  table.insert(choices, row)
end

------------------------------------------------------------
-- 可过滤项（命令 + 应用），每项带若干匹配字段
------------------------------------------------------------
local index = nil

local function buildIndex()
  actionStore = {}
  index = {}

  for cmd in pairs(commands) do
    -- subText 可以是函数：每次建索引时动态求值（例如展示当前代理状态）
    local subText = type(cmd.subText) == 'function' and cmd.subText() or cmd.subText
    local fields = { cmd.text, subText, cmd.keyword }
    if cmd.aliases then
      for _, alias in ipairs(cmd.aliases) do
        table.insert(fields, alias)
      end
    end
    table.insert(index, {
      fields = fields,
      row = {
        text = cmd.keyword and (cmd.keyword .. '  ' .. cmd.text) or cmd.text,
        subText = subText,
        image = cmd.image,
      },
      action = function()
        if cmd.action then cmd.action('') end
      end,
    })
  end

  if apps then
    for _, app in ipairs(apps) do
      local path = app.path
      table.insert(index, {
        fields = { app.name },
        row = {
          text = app.name,
          subText = '应用',
          image = appIcon(path),
        },
        action = function()
          hs.application.open(path)
        end,
      })
    end
  end
end

------------------------------------------------------------
-- Lua 过滤：大小写不敏感子串，任一匹配字段命中即可
------------------------------------------------------------
local function itemMatches(item, q)
  for _, f in ipairs(item.fields) do
    if f and string.find(string.lower(f), q, 1, true) then
      return true
    end
  end
  return false
end

------------------------------------------------------------
-- 构造当前 query 的候选（动态形态优先，其次 Lua 过滤）
------------------------------------------------------------
local function buildKeywordChoices(choices, query)
  local keyword, arg = query:match('^(%S+)%s+(.*)$')
  if not keyword then return false end
  for cmd in pairs(commands) do
    if cmd.keyword and cmd.keyword:lower() == keyword:lower() then
      addAction(choices, {
        text = query .. '   →  ' .. cmd.text,
        subText = '参数：' .. (arg ~= '' and arg or '（空）') .. '  —  回车执行',
        image = cmd.image,
      }, function()
        if cmd.action then cmd.action(arg) end
      end)
      return true
    end
  end
  return false
end

local function buildUrlChoices(choices, query)
  local url = query:match('^https?://%S+%.%S+')
  if not url then return false end
  addAction(choices, {
    text = query .. '   →  打开网址',
    subText = url,
  }, function()
    hs.execute('open "' .. url .. '"')
  end)
  return true
end

local function buildChoices(query)
  actionStore = {}
  local choices = {}

  if buildKeywordChoices(choices, query) then return choices end
  if buildUrlChoices(choices, query) then return choices end

  local limit = query == '' and CONFIG.emptyLimit or CONFIG.matchLimit

  if query == '' then
    -- 空查询：直接取前 N 项（命令在前）
    for i = 1, math.min(limit, #index) do
      local item = index[i]
      addAction(choices, item.row, item.action)
    end
  else
    local q = string.lower(query)
    for _, item in ipairs(index) do
      if itemMatches(item, q) then
        addAction(choices, item.row, item.action)
        if #choices >= limit then break end
      end
    end
  end

  return choices
end

local function completion(choice)
  if choice and choice.__id then
    local fn = actionStore[choice.__id]
    if fn then fn() end
  end
end

------------------------------------------------------------
-- Chooser
------------------------------------------------------------
local proxyChooser -- 代理二级选择面板（前向声明，供 toggle 引用）
chooser = hs.chooser.new(completion)
assert(chooser, 'hs.chooser 不可用')
chooser:width(CONFIG.width)
chooser:rows(CONFIG.rows)
chooser:placeholderText('输入命令、应用名，或网址…')
-- bgDark 是当前版本暗色背景 API（新版叫 darkMode）
if chooser.bgDark then
  chooser:bgDark(true)
else
  pcall(function() chooser:darkMode(true) end)
end
-- 关闭原生过滤：列表已由 Lua 按 query 过滤好
chooser:searchSubText(false)

------------------------------------------------------------
-- 唤出时临时切系统输入法，关闭后切回（规避第三方输入法卡顿）
------------------------------------------------------------
local savedSource = nil

local function switchToTempLayout()
  if not CONFIG.tempLayout then return end
  local cur = hs.keycodes.currentSourceID()
  if cur ~= CONFIG.tempLayout then
    savedSource = cur
    hs.keycodes.currentSourceID(CONFIG.tempLayout)
  end
end

local function restoreLayout()
  if savedSource then
    hs.keycodes.currentSourceID(savedSource)
    savedSource = nil
  end
end

local refreshPending = false
local function scheduleRefresh()
  if not chooser:isVisible() or refreshPending then return end
  refreshPending = true
  hs.timer.doAfter(CONFIG.refreshDelay, function()
    refreshPending = false
    if chooser:isVisible() then
      chooser:choices(buildChoices(chooser:query()))
    end
  end)
end
chooser:queryChangedCallback(scheduleRefresh)

local function show()
  if not apps then loadApps() end
  -- 每次唤出都重建索引，使动态 subText（如当前代理状态）保持最新
  buildIndex()
  switchToTempLayout()
  chooser:query('')
  chooser:choices(buildChoices(''))
  chooser:show()
end

-- 面板以任何方式关闭（选中、Esc、再按热键 cancel）后恢复原输入法
chooser:hideCallback(restoreLayout)

-- 热键切换：已打开时再按一次关闭
local function toggle()
  if proxyChooser and proxyChooser:isVisible() then
    proxyChooser:cancel()
  elseif chooser:isVisible() then
    chooser:cancel()
  else
    show()
  end
end

hs.hotkey.bind(CONFIG.hotkey[1], CONFIG.hotkey[2], toggle)

-- 后台预取应用并建索引，首次唤出零等待
hs.timer.doAfter(0.5, function()
  loadApps()
  buildIndex()
end)

------------------------------------------------------------
-- 内置命令（按需增删）
------------------------------------------------------------

-- g hello → Google 搜索
register(makeOpen('Google 搜索',
  'https://www.google.com/search?q=%s',
  { keyword = 'g', subText = '关键字 g + 空格 + 内容' }))

register(makeShell('清空废纸篓', '/bin/rm -rf ~/.Trash/*',
  { subText = '不可恢复，谨慎使用' }))

register(makeShell('锁屏', '/System/Library/CoreServices/Menu\\ Extras/User.menu/Contents/Resources/CGSession -suspend'))

register(makeShell('打开 Hammerspoon 配置', 'open ~/.hammerspoon'))

-- 同步笔记目录（由 modules.sync_git 提供全局 notes_sync）
register({
  text = '同步笔记目录',
  subText = 'git commit / pull --rebase / push ~/notes',
  keyword = 'sync',
  action = function()
    if type(notes_sync) == 'function' then
      notes_sync()
      hs.alert.show('已触发笔记同步', { duration = 1 })
    else
      hs.alert.show('notes_sync 不可用：请确认 modules.sync_git 已加载', { duration = 3 })
    end
  end,
})

-- 代理切换（由 modules.feat_auto_proxy 提供 setProxy / refreshStatus / current）
local autoProxy = require('modules.feat_auto_proxy')

local PROXY_OPTIONS = { {
  action = 'remote',
  label = '远程代理',
  detail = '192.168.31.101:7890',
}, {
  action = 'local',
  label = '本机代理',
  detail = '127.0.0.1:7890',
}, {
  action = 'off',
  label = '关闭代理',
  detail = '关闭系统 HTTP/HTTPS/SOCKS 代理',
} }

local proxyActionStore = {}

local function proxyDescription()
  local cur = autoProxy.current and autoProxy.current()
  if cur == 'remote' then return '当前：远程代理（192.168.31.101:7890），回车切换…' end
  if cur == 'local' then return '当前：本机代理（127.0.0.1:7890），回车切换…' end
  if cur == 'off' then return '当前：代理已关闭，回车切换…' end
  return '当前状态未知，回车选择…'
end

local function buildProxyChoices()
  proxyActionStore = {}
  local choices = {}
  local cur = autoProxy.current and autoProxy.current()
  for _, opt in ipairs(PROXY_OPTIONS) do
    local id = #proxyActionStore + 1
    proxyActionStore[id] = opt.action
    local mark = (cur == opt.action) and '✓ ' or ''
    table.insert(choices, {
      text = mark .. opt.label,
      subText = opt.detail,
      __id = id,
    })
  end
  return choices
end

local function showProxyChooser()
  -- 先用缓存状态立即展示，避免等待 networksetup 读取完成
  proxyChooser:choices(buildProxyChoices())
  proxyChooser:show()
  autoProxy.refreshStatus(function()
    if proxyChooser:isVisible() then
      proxyChooser:choices(buildProxyChoices())
    end
  end)
end

proxyChooser = hs.chooser.new(function(choice)
  if choice and choice.__id then
    local action = proxyActionStore[choice.__id]
    if action and type(autoProxy.setProxy) == 'function' then
      autoProxy.setProxy(action)
    end
  end
end)
proxyChooser:width(CONFIG.width)
proxyChooser:rows(4)
proxyChooser:placeholderText('选择要切换到的代理…')
proxyChooser:searchSubText(false)
if proxyChooser.bgDark then
  proxyChooser:bgDark(true)
else
  pcall(function() proxyChooser:darkMode(true) end)
end

register({
  text = '切换代理',
  subText = proxyDescription,
  aliases = { 'proxy', '代理' },
  action = showProxyChooser,
})

register({
  text = '重新加载 Hammerspoon',
  subText = 'Reload Config',
  action = function()
    hs.reload()
  end,
})

return {
  register = register,
  makeShell = makeShell,
  makeOpen = makeOpen,
  urlEncode = urlEncode,
  show = show,
  chooser = chooser,
}
