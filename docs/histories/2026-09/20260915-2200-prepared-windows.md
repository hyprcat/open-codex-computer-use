## [2026-09-15 22:00] | Task: macOS 窗口准备与归位 tool

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `Claude Opus 5`
* **Runtime**: `Claude Code CLI / macOS`

### 📥 User Query
> 把 fork 里已经验证过的窗口准备流程整理成上游 PR（基于 sky_key 后台输入那条分支）。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`

**Key Actions:**
- **[AgentPreparation]**: 新增 `prepare_app` 的实现：只读地解析应用当前窗口，必要时开新窗口或 reopen，再把窗口停到 agent display 上。
- **[新窗口]**: `SkyKeyboardDispatcher.pressNewWindow` 走菜单栏的 New Window 条目——窗口全在别的 Space 上时应用仍然有菜单栏；不用 Cmd-N 是因为 Notes / Reminders / Music / Calendar 会把它理解成新建笔记、提醒、播放列表或日程，直接写进用户自己的窗口。菜单查找从「匹配快捷键」泛化成「匹配任意谓词」。
- **[归位]**: `restore_prepared_window` 把窗口放回原位置，`close_prepared_window` 按窗口自己的关闭按钮关掉；`prepare_app` 自己打开的窗口在归位时一并关闭。被 sheet 顶住没关掉的窗口回到用户屏幕上，不再停留在 agent display。
- **[焦点]**: `SkyLightSPI` 增加 `frontProcess()` / `restoreFrontProcess()`，`prepare_app` 的每条退出路径都把前台进程还原回调用前的那个；另增 `fullScreenSpaces()`。
- **[边界情况]**: 全屏 Space 里的窗口直接拒绝处理；被 reopen 顺带取消最小化的窗口按「打开」状态归位，不重新最小化。
- **[复用]**: `AgentDisplay.isRestored` 重新作为归位判定的共用谓词，归位路径直接调用它，容差逻辑不再内联重复一份。

### 🧠 Design Intent (Why)
agent 要能干活，又不能把用户的屏幕占了。把目标窗口移到单独的 display 上，两边就不用抢同一块屏幕。

这里的难点几乎都在归位：用户的窗口必须回到他们放的位置，agent 自己开的窗口必须关掉，而「关掉」只能按窗口自己的关闭按钮——菜单里的 Close Window 作用于当前 main window，可能是完全另一个窗口。

全屏窗口选择不碰，是因为任何处理方式都会打断用户：重新打开会把他们切到那个 Space，而全屏窗口本身也搬不动。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AgentPreparation.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AgentDisplay.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AppDiscovery.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SkyKeyboardSimulation.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SkyLightSPI.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseToolDispatcher.swift`
