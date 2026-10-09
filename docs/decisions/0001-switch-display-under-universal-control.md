# 决策记录 0001：放弃「Opt+Tab 切换鼠标所在显示器」（通用控制场景）

- 状态：已放弃，模块已删除
- 日期：2026-10-09
- 涉及模块：`modules/feat_switch_display.lua`（已删除）、`init.lua`、`modules/feat_peek_app.lua`（保留但停用）

## 背景

需求：按 `Opt+Tab` 把鼠标移动到「鼠标所在显示器」之外的另一块显示器。

最初以为第二块屏幕是**随航（Sidecar）iPad**，实际环境是：MacBook Pro 通过**通用控制（Universal Control）**连接了一台 **Mac mini**，想用一套键鼠在两台机器间切换。

## 结论

在通用控制场景下，无法从本机（MBP）用 Hammerspoon 把鼠标切到 Mac mini，该功能放弃并删除。

## 关键区分：随航 / AirPlay ≠ 通用控制

| | 随航 iPad / AirPlay 到 Mac | 通用控制 |
|---|---|---|
| 对方设备对本机的意义 | 一块**真实的本地显示器**（NSScreen） | 一台**独立的 Mac**，只是共享键鼠 |
| `hs.screen.allScreens()` | 能看到 | **看不到**，永远只有本机屏幕 |
| 光标如何过去 | 在同一块桌面坐标空间内移动 | 必须**持续把光标推向屏幕边缘并穿过** |

实测本机在通用控制会话中，`hs.screen.allScreens()` 与 IOKit（framebuffer / `AppleDisplay`）都只有内置屏一块；但 `UniversalControl.app` 进程与 HID 中的 `V-UC Automouse` 虚拟鼠标都在，证明会话本身是正常的。

## 为什么实现不了

1. **没有目标屏幕坐标**：mini 不是本地屏幕，桌面坐标空间里不存在可移动过去的坐标。`hs.mouse.absolutePosition()` 设到屏外会被系统钳制在屏幕边缘。
2. **合成鼠标事件无法穿过通用控制边界**：通用控制只承认**真实 HID 设备**的推边动作。用 `hs.eventtap.event.newMouseEvent(mouseMoved, ...)` 发送越界坐标（实测两种方式）均被钳制，光标停在边缘：
   - 单帧瞬时连发 7 个事件，最远 `y=-200`；
   - 分 14 帧、间隔 25ms、历时约 430ms 持续顶住边缘，最远 `y=-400`。
3. **私有接口不可用**：`UniversalControl.app`（内部名 EnsembleAgent）通过私有 Swift XPC（`DisplayControllerProtocol`、`ConnectionCoordinator` 等）管理连接，受系统权限保护，第三方无法调用。

## 什么情况下该需求可以成立

1. **第二块屏是真实本地显示器**（外接显示器，或随航 iPad，或「AirPlay 接收器」方式接入的 Mac）：
   - `hs.screen.allScreens()` 能枚举到，最初版本的 `feat_switch_display`（按比例映射光标相对位置）即可直接工作。
   - 用 Mac 当目标屏时，需在目标 Mac 开启「系统设置 → 共享 → AirPlay 接收器」，代价是扩展期间该 Mac 屏幕被占用，不能同时当独立工作站。
2. **两台 Mac 都装 Hammerspoon，走网络协作**：
   - mini 起 `hs.httpserver` 接收请求后在本地 warp 光标（本地 warp 会被通用控制承认为真实移动）；
   - MBP 的快捷键发 HTTP 请求让 mini「吸」光标，反向同理。
   - 本次未采用，将来若需要可按此方案重新实现。

## 相关变更

- 删除 `modules/feat_switch_display.lua`。
- `init.lua` 中移除其 `require`；`modules/feat_peek_app.lua`（`Opt+Tab` 隐藏/恢复 App）此前为让位而停用，保持停用状态，文件保留。
