-- Git 仓库自动同步（支持多个目录，互不干扰）
-- 触发方式：Obsidian 运行期间每 CHECK_INTERVAL 秒检查一次（启动后立即先检查一次），
--           改动文件静默满 quietSeconds 秒才提交；每次检查先确认 Obsidian 仍在运行，
--           已退出则停止轮询。Obsidian 退出瞬间无条件同步一次（不要求静默）。
-- 每个仓库独立执行：提交本地改动 -> rebase 拉取 -> 推送
-- 也可在 Hammerspoon Console 中手动触发，如 notes_sync()、sync_git_all()（手动触发不判断静默）

-- ============================== 配置区 ==============================
-- dir:           仓库绝对路径
-- quietSeconds:  定时检查时，待提交文件最后修改距今超过该秒数才提交，避免提交写入中的文件
-- label:         通知中显示的名称（默认取目录名）
local CHECK_INTERVAL = 180 -- Obsidian 运行期间的检查间隔（秒）
local REPOS = {
	{
		dir = os.getenv("HOME") .. "/notes",
		quietSeconds = 180, -- 定时检查：文件静默满 3 分钟才提交
		label = "notes",
		manualName = "notes_sync", -- 暴露的全局手动触发函数名（可选）
	},
	-- 追加更多仓库示例：
	-- {
	-- 	dir = os.getenv("HOME") .. "/dotfiles",
	-- 	quietSeconds = 300,
	-- },
}
local TRIGGER_APP = "Obsidian" -- 该 App 启动/退出时触发同步
-- ===================================================================

-- 离线/网络类错误特征，命中则保持安静（定时任务频繁报错太吵）
local NETWORK_ERROR_PATTERNS = {
	"Could not resolve",
	"Network is unreachable",
	"Operation timed out",
	"Connection timed out",
	"Connection refused",
	"Could not read from remote",
}

-- 同步脚本：在 bash 中一次跑完，通过退出码区分错误类型
-- 0=成功 10=目录/git异常 11=add失败 12=commit失败
-- 13=pull失败 14=push失败 20=rebase冲突未解决 30=文件刚修改，本轮跳过
-- 参数：$1=仓库目录 $2=静默秒数
local SYNC_SCRIPT = [[
set -u
REPO_DIR="$1"
QUIET_SECONDS="$2"
cd "$REPO_DIR" || exit 10
export GIT_TERMINAL_PROMPT=0
git rev-parse HEAD >/dev/null 2>&1 || exit 10

# 上一次 rebase 冲突未解决时不再继续，等人工处理
if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
  exit 20
fi

# 有改动文件在最近 QUIET_SECONDS 秒内被修改过，说明可能还在编辑，本轮跳过
NOW=$(date +%s)
while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  AGE=$((NOW - $(stat -f %m "$f")))
  if [ "$AGE" -lt "$QUIET_SECONDS" ]; then
    exit 30
  fi
done < <(git ls-files -m -o --exclude-standard -z)

BEFORE=$(git rev-parse HEAD)
git add -A || exit 11
COMMITTED=0
if ! git diff --cached --quiet; then
  git commit -q -m "auto sync: $(date '+%Y-%m-%d %H:%M:%S')" || exit 12
  COMMITTED=1
fi

git pull --rebase -q || exit 13
AFTER=$(git rev-parse HEAD)

# 本地领先远端（本次提交或历史遗留提交）才需要 push
AHEAD=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
if [ "$AHEAD" -gt 0 ]; then
  git push -q || exit 14
fi

echo "NOTES_SYNC committed=$COMMITTED before=$BEFORE after=$AFTER"
]]

local function isNetworkError(msg)
	for _, pat in ipairs(NETWORK_ERROR_PATTERNS) do
		if msg:find(pat, 1, true) then
			return true
		end
	end
	return false
end

-- 为单个仓库创建同步器
local function createSyncer(cfg)
	local state = {
		dir = cfg.dir,
		label = cfg.label or cfg.dir:match("([^/]+)/?$"),
		quietSeconds = cfg.quietSeconds or 300,
		syncing = false,
		rebaseConflictNotified = false, -- rebase 冲突只通知一次，避免刷屏
	}

	local function notify(text)
		hs.notify.new({
			title = "Git 同步 · " .. state.label,
			informativeText = text,
			hasActionButton = false,
		}):send()
	end

	local function handleResult(code, stdout, stderr)
		state.syncing = false
		local msg = (stderr or "") .. (stdout or "")

		if code == 0 then
			state.rebaseConflictNotified = false
			local committed = stdout:match("committed=(%d)")
			local before = stdout:match("before=([0-9a-f]+)")
			local after = stdout:match("after=([0-9a-f]+)")
			if committed == "1" then
				notify("本地改动已提交并推送 ✓")
			elseif before ~= after then
				notify("已拉取远端更新")
			end
			-- 无任何变化时保持安静
			return
		end

		if code == 30 then
			return -- 文件还在编辑中，静默等下一轮
		end

		if code == 20 then
			if not state.rebaseConflictNotified then
				notify("⚠️ rebase 冲突未解决，请手动到该目录处理")
				state.rebaseConflictNotified = true
			end
			return
		end

		if (code == 13 or code == 14) and isNetworkError(msg) then
			return -- 离线，静默跳过
		end

		local detail = msg:gsub("%s+$", "")
		if #detail > 200 then
			detail = detail:sub(-200)
		end
		notify("同步失败（code " .. tostring(code) .. "）：" .. detail)
	end

	-- quietSeconds 不传（手动触发）时按 0 处理，即不判断静默
	local function sync(quietSeconds)
		if state.syncing then
			return -- 上一次还没跑完（网络挂起时防止任务堆积）
		end
		state.syncing = true
		-- callback 签名：(exitCode, stdOut, stdErr)
		hs.task
			.new("/bin/bash", handleResult, {
				"-c", SYNC_SCRIPT, "git_sync", state.dir, tostring(quietSeconds or 0),
			})
			:start()
	end

	-- 暴露手动触发入口
	if cfg.manualName then
		_G[cfg.manualName] = sync
	end

	return sync
end

-- 启动所有仓库；同时暴露通用手动触发入口
local syncers = {}
for _, repo in ipairs(REPOS) do
	syncers[repo.dir] = createSyncer(repo)
end

-- 手动同步全部仓库；也可 sync_git("~/dotfiles") 按目录触发。手动触发不判断静默
function sync_git_all()
	for _, sync in pairs(syncers) do
		sync(0)
	end
end

function sync_git(dir)
	local sync = syncers[dir:gsub("^~", os.getenv("HOME"))]
	if sync then
		sync(0)
	else
		hs.notify.new({
			title = "Git 同步",
			informativeText = "未配置该目录：" .. dir,
		}):send()
	end
end

-- Obsidian 运行期间：启动即检查一次，之后每 CHECK_INTERVAL 秒检查一次
-- 定时检查要求文件静默满各自仓库的 quietSeconds
-- 某次检查发现 Obsidian 已退出：停止轮询并无条件同步一次（quietSeconds=0）
-- 不监听退出事件——退出后的补同步只由轮询检查驱动
local function obsidianRunning()
	return hs.application.get(TRIGGER_APP) ~= nil
end

-- 全局变量持有 watcher/timer 防 GC
git_sync_poll_timer = nil

local function stopPolling()
	if git_sync_poll_timer then
		git_sync_poll_timer:stop()
		git_sync_poll_timer = nil
	end
end

local function scheduledCheck()
	-- 发现 Obsidian 已退出：停掉轮询，无条件同步一次（不要求文件静默）
	if not obsidianRunning() then
		stopPolling()
		sync_git_all()
		return
	end
	for _, repo in ipairs(REPOS) do
		syncers[repo.dir](repo.quietSeconds or 0)
	end
end

local function startPolling()
	-- 先停旧定时器再建新的，避免 Obsidian 快速退出又重开时出现多个轮询
	-- 上一次同步任务未跑完时，syncer 内的 syncing 锁会让重叠的触发直接跳过
	stopPolling()
	scheduledCheck() -- 启动后立即检查一次
	git_sync_poll_timer = hs.timer.doEvery(CHECK_INTERVAL, scheduledCheck)
end

git_sync_app_watcher = hs.application.watcher.new(function(appName, event)
	if appName ~= TRIGGER_APP or event ~= hs.application.watcher.launched then
		return
	end
	startPolling()
end)
-- 只订阅 launched；terminated 不监听（注释掉），退出后的补同步由轮询检查发现应用不在来驱动
-- git_sync_app_watcher:start()
git_sync_app_watcher:start(hs.application.watcher.launched)

-- Hammerspoon 启动/重载配置时 Obsidian 已在运行，则直接开始轮询
if obsidianRunning() then
	startPolling()
end
