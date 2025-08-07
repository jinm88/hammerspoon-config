-- modules/peek_app.lua
-- 用于存储最后被“隐藏”的应用程序的进程ID (PID)
local lastHiddenAppPID = nil
-- 用于存储应用被隐藏时的时间戳（Unix时间，秒）
local hiddenTimestamp = nil
-- 定义超时时间（秒）
local HIDE_TIMEOUT_SECONDS = 1800

-- 设置快捷键：Option + tab
-- 您可以根据自己的喜好修改这里的快捷键
hs.hotkey.bind({"alt"}, "tab", function()
    local currentFrontApp = hs.application.frontmostApplication()
    local currentTime = os.time() -- 获取当前Unix时间戳

    -- 步骤1: 检查是否存在上次隐藏的应用记录，并判断是否超时
    if lastHiddenAppPID and hiddenTimestamp then
        local timeElapsed = currentTime - hiddenTimestamp
        if timeElapsed > HIDE_TIMEOUT_SECONDS then
            -- 如果记录的应用已超时，清除记录
            print("Hammerspoon: Previously hidden app (PID " .. lastHiddenAppPID .. ") record timed out. Clearing.")
            hs.notify.new({title="Hammerspoon", informativeText="上次隐藏的应用记录已超时，将隐藏当前应用。" }):send()
            lastHiddenAppPID = nil
            hiddenTimestamp = nil
        end
    end

    -- 定义一个通用的隐藏函数，以适应不同应用的隐藏方式
    local function hideApplication(app)
        if not app then return end

        local appTitle = app:title()
        print("Hammerspoon: Attempting to hide app: " .. appTitle)

        -- 优先尝试标准 hide() 方法
        if not app:isHidden() then
            app:hide()
            -- 给予应用短暂时间响应 hide() 指令
            hs.timer.doAfter(0.1, function()
                if app:isHidden() then
                    print("Hammerspoon: Standard hide() successful for '" .. appTitle .. "'.")
                    hs.notify.new({title="Hammerspoon", informativeText="已隐藏应用: " .. appTitle }):send()
                else
                    -- 如果 hide() 之后应用没有真正隐藏 (例如Arc)，则尝试模拟 Command+H
                    print("Hammerspoon: Standard hide() failed or reverted for '" .. appTitle .. "', attempting Command+H.")
                    -- 激活应用以确保键盘事件能正确发送
                    app:activate()
                    hs.eventtap.keyStroke({"cmd"}, "h")
                    hs.notify.new({title="Hammerspoon", informativeText="已通过模拟Cmd+H隐藏应用: " .. appTitle }):send()
                end
                lastHiddenAppPID = app:pid()
                hiddenTimestamp = os.time() -- 记录隐藏时间
            end)
        else
            print("Hammerspoon: App '" .. appTitle .. "' is already hidden. No action taken.")
            hs.notify.new({title="Hammerspoon", informativeText="当前应用已隐藏，无需重复操作。" }):send()
        end
    end

    -- 步骤2: 根据记录状态执行操作
    if lastHiddenAppPID then
        -- 如果存在未超时的隐藏应用记录，尝试激活它
        local appToUnhide = hs.application.get(lastHiddenAppPID)
        if appToUnhide then
            if appToUnhide:isHidden() then
                -- 如果应用确实是隐藏的，则取消隐藏并激活
                appToUnhide:unhide()
                appToUnhide:activate()
                print("Hammerspoon: Previously hidden app '" .. appToUnhide:title() .. "' unhidden and activated.")
                hs.notify.new({title="Hammerspoon", informativeText="已激活上次隐藏的应用: " .. appToUnhide:title() }):send()
                lastHiddenAppPID = nil -- 激活后清除记录
                hiddenTimestamp = nil
            else
                -- 如果记录的应用没有隐藏（可能用户手动激活了，或者它本来就可见）
                print("Hammerspoon: Previously hidden app (PID " .. lastHiddenAppPID .. ") is already visible. Clearing record.")
                hs.notify.new({title="Hammerspoon", informativeText="上次隐藏的应用已可见，将隐藏当前应用。" }):send()
                lastHiddenAppPID = nil -- 清除记录，因为它不再是“隐藏”状态
                hiddenTimestamp = nil
                -- 继续执行隐藏当前应用的逻辑
                hideApplication(currentFrontApp)
            end
        else
            -- 如果记录的应用已关闭或不存在
            print("Hammerspoon: Previously hidden app (PID " .. lastHiddenAppPID .. ") not found or no longer running. Clearing record.")
            hs.notify.new({title="Hammerspoon", informativeText="上次隐藏的应用已关闭或不存在，将隐藏当前应用。" }):send()
            lastHiddenAppPID = nil -- 清除无效记录
            hiddenTimestamp = nil
            -- 继续执行隐藏当前应用的逻辑
            hideApplication(currentFrontApp)
        end
    else
        -- 如果没有记录上次隐藏的应用（或记录已被清除/超时），则隐藏当前应用
        if currentFrontApp then
            hideApplication(currentFrontApp)
        else
            print("Hammerspoon: No frontmost application to hide.")
            hs.notify.new({title="Hammerspoon", informativeText="没有前台应用可隐藏。" }):send()
        end
    end
end)

-- 启动时提示用户快捷键已设置
-- 这个通知只在 Hammerspoon 启动或重载配置时显示
hs.notify.new({title="Hammerspoon", informativeText="Hammerspoon 窗口管理快捷键已加载：\nOption + Space: 隐藏/激活前台应用（5分钟超时）" }):send()

print("Hammerspoon: Hide/Unhide Frontmost App with timeout hotkey loaded.")