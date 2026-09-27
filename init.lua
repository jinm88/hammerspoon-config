-- 关闭 hs.hotkey 的日志输出
hs.hotkey.setLogLevel('warning')

-- 只需要引入 ipc 模块，Hammerspoon 就会自动开启内部默认的命令行监听端口
require("hs.ipc")

-- eventtap 健康守护：须在各事件监听模块之前加载
require('modules.eventtap_health')


-- 配置定位服务权限，获取wifi需要用到
-- print(hs.location.get())
-- require('modules.caffeine')
-- require('modules.wifi_mute')

require('modules.feat_ocr')
require('modules.hotkey_app')
require('modules.hotkey_arrow_keys')
require('modules.auto_switch_audio')
require('modules.fix_paste_blocking')
require('modules.fix_smooth_scrolling')
require('modules.feat_peek_app')
require('modules.feat_wifi_status')
require('modules.input_method_indicator')
require('modules.fix_cursor_ui_view')
require('modules.feat_smart_ime')
require('modules.auto_disconnect_bt_mic')

-- --------------------------------------------------
-- Spoons（由 SpoonInstall 统一管理，缺失的 Spoon 会从官方仓库自动下载安装）
-- --------------------------------------------------
hs.loadSpoon('SpoonInstall')
spoon.SpoonInstall.use_syncinstall = true
local Install = spoon.SpoonInstall

-- 输入法名称（InputSourceSwitch 用名称而非 sourceID）
-- 本机输入法名称可在 Hammerspoon Console 执行 hs.inspect(hs.keycodes.methods()) 查看
local WeType = '微信输入法'

-- 根据 App 自动切换输入法
Install:andUse('InputSourceSwitch', {
  fn = function(app)
    app:setApplications({
      ['终端'] = 'ABC',
      ['Ghostty'] = WeType,
      ['iTerm2'] = 'ABC',
      ['Visual Studio Code'] = 'ABC',
      ['Sublime Text'] = 'ABC',
      ['CotEditor'] = 'ABC',
      ['WebStorm'] = 'ABC',
      ['Obsidian'] = WeType,
      ['WeChat'] = WeType,
      ['Telegram'] = WeType,
    })
    app:start()
  end
})

-- 划词翻译
Install:andUse('PopupTranslateSelection', {
  hotkeys = {
    translate = { {'alt', 'shift'}, 'e' },
  }
})
