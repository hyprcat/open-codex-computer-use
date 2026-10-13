# App Intent（macOS）

App 提供 App Intent 时，Agent 可以先读取动作和参数，再直接调用。没有入口时，继续用原来的界面操作。

不需要自己创建或绑定快捷指令。OCU 会生成执行模板；首次使用需要在系统的 Shortcuts 窗口里确认添加。更换参数值会复用模板，更换参数名称、动作定义或签名身份会生成新模板。

## 怎么用

先列出 App 提供的动作。发现过程不启动 App，也不读取窗口。

```js
var app = await cua.getApp("Example App", { initialState: false });
nodeRepl.write(await app.listIntents({ limit: 20 }));
```

从返回的 `id` 和 `parameters` 选择动作、填写参数。下面的动作名和参数是示例，以实际发现的结果为准。

```js
nodeRepl.write(await app.prepareIntent("Echo", { text: "hello" }));
// 在 Shortcuts 中检查模板，确认添加后再执行。
nodeRepl.write(await app.runIntent("Echo", { text: "new value" }));
```

命令行也可以调用：

```sh
ocu call list_intents --args '{"app":"Example App","limit":20}'
ocu call run_intent --args '{"app":"Example App","action_id":"Echo","parameters":{"text":"hello"},"prepare":true}'
ocu call run_intent --args '{"app":"Example App","action_id":"Echo","parameters":{"text":"new value"}}'
```

模板放在 OCU 配置文件同级的 `intent-templates/` 目录，默认是 `~/.config/ocu/intent-templates/`。模板只保存参数名称和引用，每次执行使用新的临时 JSON 文件，结束后删除。安装后按 Shortcuts 的 UUID 调用，重命名不会换错目标。

添加模板和执行授权是两回事。首次运行时，Shortcuts 可能另行询问 App 权限，或显示 “Allow … to output …?”。检查内容后再允许；`Allow Once` 只允许这一次输出，`Always Allow` 会记住这个快捷指令的输出授权。`prepareIntent` 不执行动作，也不会提前完成这些授权。

## 接口和结果

| JS 接口 | Native tool | 作用 |
| --- | --- | --- |
| `app.listIntents({ limit, offset })` | `list_intents` | 返回动作、参数、`can_execute` 和不支持的原因。默认 50 项，最多 100 项；用 `next_offset` 翻页。 |
| `app.prepareIntent(id, parameters)` | `run_intent`，`prepare: true` | 准备模板或检查是否已添加；不执行动作。 |
| `app.runIntent(id, parameters)` | `run_intent` | 校验参数，使用已添加的模板执行。 |

| `status` | 含义 | 后续处理 |
| --- | --- | --- |
| `available` | 发现了动作目录 | 查看各动作的 `can_execute`。 |
| `needs_approval` | 模板尚未准备或尚未添加 | 准备并确认添加，或使用 GUI。 |
| `ready` | 模板已添加 | 可以执行。 |
| `unavailable` | 平台、动作、参数类型或系统工具不支持 | `safe_to_fallback: true` 时可以使用 GUI。 |
| `busy` | 同一模板正在准备或执行 | 等待当前调用结束。 |
| `completed` | 系统报告执行成功 | 读取 `output`；最多返回 64 KiB，超出会标记 `output_truncated`。 |
| `unknown` | 已开始调用，但没有可靠的结束结果 | 先检查操作是否发生，再决定重试。不要自动重复调用或改走 GUI。 |
| `failed` | 子进程未能启动 | 查看失败原因。 |

参数目前支持字符串、布尔值、JS 安全整数范围内的整数、有限小数和元数据中列出的枚举值。拒绝未知参数和错误类型，总输入最多 64 KiB。必填的实体、数组、文件、富文本等类型，以及无法转换的返回类型，会标为不可执行；可选的不支持参数可以省略。

这是实验性能力：发现读取主 App bundle 的 `Metadata.appintents/extract.actionsdata`，目前识别其中的 JSON `version: 1`。这个格式不是 Apple 的公开发现 API；旧 SiriKit 定义、扩展中的独立定义和未来格式暂不支持。`can_execute` 表示参数和格式符合当前实现，系统权限或 App 自身仍可能阻止执行。

执行通过系统 `shortcuts` 命令，20 秒没有可靠结果就返回 `unknown`。等待系统授权也可能超时，此时动作可能已经执行，只是结果尚未允许输出。先检查弹窗和操作结果，再决定是否重试。系统提示需要单独处理，OCU 不会自动允许。用户添加后可以在 Shortcuts 中编辑模板；OCU 无法通过公开 CLI 核验其内容，请保留生成的动作和参数引用。

## 本地集成测试

安装完整 Xcode 后，构建隔离测试 App：

```sh
python3 scripts/build-app-intent-fixture.py
```

把这个 App 安装并打开一次，让 Launch Services 能发现 `dev.ocu.IntentFixture`。它只回显测试参数、写临时测试记录，不读取个人 App 或数据。再构建 OCU 并测试：

```sh
swift build
python3 scripts/test-app-intent-fixture.py --prepare
# 在 Shortcuts 中检查并添加模板。
python3 scripts/test-app-intent-fixture.py
```

测试时留意系统弹窗。两次执行必须返回各自的完整输入；`Allow Once` 可能让第二次再次询问，愿意保留这个测试模板的输出授权时可选择 `Always Allow`。遇到未知结果会立即停止，不会自动重试。系统 CLI 用法见 [Apple 的说明](https://support.apple.com/guide/shortcuts-mac/apd455c82f02/mac)。
