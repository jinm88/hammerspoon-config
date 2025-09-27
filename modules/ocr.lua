-- ==========================================================
-- macOS 原生 OCR 脚本 (通过调用“快捷指令”App实现)
-- 一旦检测到截图（图片）进入剪贴板，立即执行 OCR。
-- ==========================================================

-- 步骤 1: 定义 Hammerspoon 激活热键。
local ocrHotKey = {"cmd", "shift"}
local hotKeyTrigger = "2"

-- 步骤 2: 定义您在“快捷指令”App中创建的指令名称。
-- !! 重要提示：请确保“快捷指令”App中存在一个名为 "ocr" 的指令，
--       并且该指令能从图片中提取文本并将其复制回剪贴板。
local shortcutName = "ocr"

-- 全局变量用于存储轮询定时器
local clipboardCheckTimer = nil

-- Task 1: 执行 OCR 任务 (从剪贴板获取图片并调用快捷指令)
local function runOcrTask()
    -- 3. 调用“快捷指令”App，运行指定的指令。
    --   -i "clipboard" 告诉快捷指令从剪贴板接收输入（即刚才的截图）。
    local task = hs.task.new("/usr/bin/shortcuts", function(task_code, stdout, stderr)
        -- 检查快捷指令是否成功运行
        if task_code == 0 then
            -- 4. 快捷指令运行结束后，OCR识别出的文字已经被复制到剪贴板。
            local recognizedText = hs.pasteboard.getContents()

            -- 5. 处理结果：自动粘贴或错误提示
            if recognizedText and recognizedText ~= "" then
                -- hs.alert.show(recognizedText)
            else
                hs.alert.show("OCR 失败：未识别到文本或快捷指令运行异常。", {duration = 3})
            end
        else
            -- 快捷指令执行出错
            local errorMessage = "调用快捷指令失败！请检查名称是否为：" .. shortcutName .. "\n错误码: " .. task_code .. "\nStderr: " .. (stderr or "无")
            hs.alert.show(errorMessage, {duration = 5})
        end
    end, {"run", shortcutName, "-i", "clipboard"})
    task:start()
end

-- Task 2: 轮询函数，检查剪贴板是否包含图片
local function checkClipboardForImage()
    -- 尝试读取剪贴板上的图片。
    local image = hs.pasteboard.readImage()

    if image then
        -- 成功：找到截图了！停止轮询并执行 OCR 任务
        if clipboardCheckTimer then
            clipboardCheckTimer:stop()
            clipboardCheckTimer = nil
        end
        
        -- 显式地将变量设为 nil 以助回收：
        image = nil
        
        runOcrTask()
    end

end

-- Task 3: 核心 OCR 启动函数
function runOcrFromScreenshot()
    -- 1. 模拟 Command + Shift + 4 按键，启动 macOS 区域截图模式。
    -- 注意：这里使用 hs.eventtap.keyStroke，确保截图模式被触发。
    hs.eventtap.keyStroke({"cmd", "shift"}, "4")

    -- 2. 启动轮询计时器，每 100 毫秒检查一次剪贴板
    -- 确保旧的计时器被停止
    if clipboardCheckTimer then
        clipboardCheckTimer:stop()
    end

    -- 创建新的计时器
    clipboardCheckTimer = hs.timer.new(0.1, checkClipboardForImage)
    clipboardCheckTimer:start()

    -- 设置一个最长超时，防止用户中途取消截图导致轮询无限期运行
    hs.timer.doAfter(10.0, function()
        if clipboardCheckTimer then
            clipboardCheckTimer:stop()
            clipboardCheckTimer = nil
            hs.alert.show("截图超时或取消。OCR轮询已停止。", {duration = 3})
        end
    end)

end

-- 绑定热键 (CMD + SHIFT + 2)
hs.hotkey.bind(ocrHotKey, hotKeyTrigger, runOcrFromScreenshot)
