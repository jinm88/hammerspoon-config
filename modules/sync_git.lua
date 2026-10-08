-- Git 仓库自动同步（支持多个目录，互不干扰）
-- 每个仓库独立定时执行：提交本地改动（文件静默一段时间后）-> rebase 拉取 -> 推送
-- 也可在 Hammerspoon Console 中手动触发，如 notes_sync()、sync_git_all()

-- ============================== 配置区 ==============================
-- dir:           仓库绝对路径
-- interval:      自动执行间隔（秒）
-- quietSeconds:  待提交文件最后修改距今超过该秒数才提交，避免提交写入中的文件
-- label:         通知中显示的名称（默认取目录名）
local REPOS = {
	{
		dir = os.getenv("HOME") .. "/notes",
		interval = 180,
		quietSeconds = 300,
		label = "notes",
		manualName = "notes_sync", -- 暴露的全局手动触发函数名（可选）
	},
	-- 追加更多仓库示例：
	-- {
	-- 	dir = os.getenv("HOME") .. "/dotfiles",
	-- 	interval = 600,
	-- 	quietSeconds = 300,
	-- },
}
local FIRST_RUN_DELAY = 5 -- 加载后首次执行延迟，等网络就绪
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

	local function sync()
		if state.syncing then
			return -- 上一次还没跑完（网络挂起时防止任务堆积）
		end
		state.syncing = true
		-- callback 签名：(exitCode, stdOut, stdErr)
		hs.task
			.new("/bin/bash", handleResult, nil, {
				"-c", SYNC_SCRIPT, "git_sync", state.dir, tostring(state.quietSeconds),
			})
			:start()
	end

	-- 全局表持有 timer 防 GC
	git_sync_timers = git_sync_timers or {}
	local timer = hs.timer.new(cfg.interval or 300, sync)
	timer:start()
	table.insert(git_sync_timers, timer)

	hs.timer.doAfter(FIRST_RUN_DELAY, sync)

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

-- 手动同步全部仓库；也可 sync_git("~/dotfiles") 按目录触发
function sync_git_all()
	for _, sync in pairs(syncers) do
		sync()
	end
end

function sync_git(dir)
	local sync = syncers[dir:gsub("^~", os.getenv("HOME"))]
	if sync then
		sync()
	else
		hs.notify.new({
			title = "Git 同步",
			informativeText = "未配置该目录：" .. dir,
		}):send()
	end
end
