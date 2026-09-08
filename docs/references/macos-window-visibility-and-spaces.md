# macOS 后台窗口可见性与 Space 参考

## 用途

这份笔记记录 `get_app_state` / `sky_click` / `sky_key` 如何处理被遮挡、位于其他 Space 的窗口，以及为什么这些问题要在 WindowServer（SkyLight）层面解决而不是逐个 app 打补丁。结论来自 2026-09-08 在 macOS 27.0 上对隔离 Chrome、Electron app 和本仓库 fixture 的受控测试；实机回归是 `OcclusionKeepAliveLiveTests`。

## 从 macOS 的角度看问题

一个“不抢用户焦点的 computer-use agent”要做三件事，每件在 macOS 里都有对应的原语：

| 需求 | macOS 原语 | 本仓库的用法 |
| --- | --- | --- |
| 读取窗口状态 | Accessibility API（按进程，与 Space 无关）+ ScreenCaptureKit 按 window id 捕获 backing store | `SnapshotBuilder`、`WindowCapture` |
| 窗口“是否可见” | WindowServer occlusion 状态，经 `SLSPackagesEnableWindowOcclusionNotifications` 注册的通知送达 app，AppKit 暴露为 `NSWindow.occlusionState` | `WindowOcclusionKeepAlive` |
| 向后台进程投递输入 | `SLPSPostEventRecordTo`（activation / key-window record）、`SLEventPostToPid` / `CGEventPostToPid` | `sky_click`、`sky_key` |
| Space | `SLSCopyManagedDisplaySpaces`、`SLSMoveWindowsToManagedSpace`、`SLSManagedDisplaySetCurrentSpace` | 只用于实验与验证，运行时不移动窗口 |

app 自己不会“知道”被遮挡；它只会收到 WindowServer 的 occlusion 通知。Chromium 收到通知后把页面设为 hidden：渲染进程停止出帧，`AXWebArea` 子树从 AX tree 消失。Electron、WebKit 同理。原生 AppKit 窗口不受影响。所以“其他 Space 的 AX tree 拿不到”的根因是 occlusion，不是 Space 本身。

## 已验证的行为

- 被完全遮挡的 Chrome：`document.visibilityState` 变为 `hidden`，AX tree 只剩窗口 chrome，没有 `AXWebArea`；`SCScreenshotManager` 仍能按 window id 捕获，`sky_click` 仍能触发 DOM click。
- 对窗口调用 `SLSPackagesEnableWindowOcclusionNotifications(cid, wid, false, &previous)`（跨进程可用，返回 0）后再遮挡：页面保持 `visible`，`AXWebArea` 保留，点击与输入正常，用户前台应用不受影响。重新启用通知不会补发当前状态，直到下一次真实变化。
- 已经被遮挡再关闭通知无效：app 会一直停留在 hidden。所以 keep-alive 只在窗口当前未被遮挡时启用，判定用 `CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow)` 的几何采样。
- `SLSPackagesEnableWindowOcclusionNotifications` 的第四个参数是可选的 `uint8_t *previous` 输出指针；`SLSLockWindowVisibleRegion(cid, wid, uint64_t *seed)` 也有输出指针，且要求窗口属于本连接（返回 1000）。签名来自 lldb 反汇编，猜错会写坏内存。
- Chromium 系（Chrome、Electron、CEF）在第一个 AX client 请求后才异步构建 web AX tree，Chrome 需要最多约 2 秒；`AXManualAccessibility` 对 Electron 返回成功，对 Chrome 返回 `attributeUnsupported`，所以不能作为唯一信号。运行时改为检查 bundle 的 `Contents/Frameworks` 是否包含 Chromium / Electron / CEF 框架。
- 全屏 Space 里的 Chrome 窗口：`visibilityState` 仍为 `visible`，`sky_click` / `sky_key` 生效，但 fullscreen 会重建窗口结构，不能作为“另一个桌面 Space”的代理测试。
- 真实的第二个桌面（`CrossSpaceLiveTests`）：Chrome 在 Desktop 2 上、用户停在 Desktop 1 且 fixture 在前台时，`SnapshotBuilder` 解析到该窗口并返回网页内容与截图，`sky_click` / `sky_key` 生效，active Space 不变，Chrome 未被激活。其他 Desktop 上的窗口 `kCGWindowIsOnscreen` 仍为 true，判断窗口所在 Space 要用 `SLSCopySpacesForWindows(cid, 0x7, [wid])`。
- macOS 26+ 第三方进程不能把别的 app 的窗口移到其他 Space：`SLSMoveWindowsToManagedSpace` / `SLSAddWindowsToSpaces` / `SLSSpaceCreate` 等都先检查 `SLSWindowManagementClientOperationsEnabled()`（依赖 window-management bridge delegate），不满足时静默返回。`SLSManagedDisplaySetCurrentSpace` 不受此限制。本仓库运行时也不需要移动窗口。

## 运行时行为

1. `get_app_state` 解析目标窗口时先看 on-screen 列表，再退到 `.optionAll`，因此其他 Space 的窗口不会再触发 activate / raise 的恢复逻辑。
2. 拍到窗口后，若窗口当前未被遮挡，就关闭它的 occlusion 通知（keep-alive），进程退出时统一恢复。之后用户遮挡它或切换 Space，app 仍认为自己可见。
3. Chromium 系 app 第一次走 tree 若没有 `AXWebArea`，在窗口可见时最多重走 3 秒；窗口被遮挡则在 tree 末尾追加说明，不等待、不激活。
4. `sky_click` / `sky_key` 只要求窗口仍属于目标进程且 app 未被隐藏，不再要求 on-screen。

## 已经被遮挡的窗口：agent display（`window_placement=agent_display`）

agent 第一次接触时就已经被遮挡或已在其他 Space 的 Chromium 窗口，没有 WindowServer 原语能在不显示的情况下把它“变可见”。macOS 自己的答案是 virtual display（`CGVirtualDisplay` 私有 ObjC 类，Screen Sharing 的 headless 会话就是这样做的）。本仓库把它做成 `get_app_state` 的显式 `window_placement=agent_display`：`AgentDisplay` 通过 `packages/OpenComputerUseVirtualDisplayShim`（ObjC，`NSClassFromString` 解析、无硬链接依赖）创建 1920×1080 的 agent 显示器，用 AX `kAXPosition` 把目标窗口的 frame 移进该显示器（不激活、不抬升），窗口随之落到该显示器的 Space 上并对其 app 真正可见；`window_placement=restore` 或进程退出时把窗口移回原位置，没有窗口停靠时销毁显示器。实机回归是 `AgentDisplayLiveTests`。spike 阶段的观察：

- `CGVirtualDisplayDescriptor` → `-[CGVirtualDisplay initWithDescriptor:]` → `CGVirtualDisplaySettings`（`hiDPI`、`modes` = `-[CGVirtualDisplayMode initWithWidth:height:refreshRate:]`）→ `applySettings:` 返回 true，得到新的 `displayID`，`SLSCopyManagedDisplaySpaces` 立刻多出一个显示器和它自己的 Space；用户的 active Space、frontmost app、鼠标位置都不变。新显示器排在主屏右侧（bounds 从 x=1512 开始），鼠标理论上可以滑进去。
- `SLSMoveWindowsToManagedSpace` 单独不能把窗口跨显示器移到那个 Space；先用 AX `kAXPosition` 把窗口 frame 移进 virtual display 的 bounds（不激活），再移 Space，`SLSCopySpacesForWindows` 就报告它在新 Space。
- 一个此前被完全遮挡、页面 `hidden`、没有 `AXWebArea` 的 Chrome 窗口，放到 virtual display 上后页面立刻 `visible`；生产 `SnapshotBuilder` 返回网页内容与截图，`sky_click` / `sky_key` 正常；结束后把窗口移回原位置与原 Space，进程退出后显示器消失。
- spike 里用 Swift KVC / IMP 直接驱动这些类会在 dealloc 崩溃；正式实现放在 ObjC shim 里，ARC 管理对象生命周期，`AgentDisplayLiveTests` 验证创建、停靠、点击输入、恢复与销毁全程无崩溃，显示器数量恢复。
- 已知副作用：agent 显示器排在主屏右侧，鼠标可能滑入；停靠期间窗口不在用户桌面上。所以它是显式 opt-in，不进入默认路径。

## 还没有解决的部分

- `CrossSpaceLiveTests` 需要机器上有第二个 Desktop（Mission Control 里手动创建；`SLSSpaceCreate` 造的 Space 不是 managed Desktop，Dock 的 Mission Control AX tree 只在鼠标悬停时才暴露 Spaces bar）。测试通过 `SLSManagedDisplaySetCurrentSpace` 切到 Desktop 2 启动 Chrome 再切回来，因为窗口不能被第三方进程跨 Space 移动。
- agent display 的鼠标滑入与显示器排列没有额外处理；`SLSSpaceCreate` 类跨 Space 移动窗口的 API 对第三方进程无效，所以停靠只能靠移动 frame。

## 参考来源

- Chromium `content/app_shim_remote_cocoa/web_contents_occlusion_checker_mac.mm`、`web_contents_view_cocoa.mm`（`isWindowOccluded:` 以 `NSWindow.occlusionState` 为准）。
- yabai `src/window_manager.c`（event record 布局）、Cua Driver（SkyLight 桥接）。
