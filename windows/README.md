# magpie-codex-router · Windows

让 Codex Desktop **保持 ChatGPT 登录**（不会每次启动都进 onboarding），同时把**模型请求和模型列表**交给你自己的网关。原理和 [macOS 版](../macOS/README.md) 一样：在 `127.0.0.1:18765` 跑一个本地 relay。

- relay 丢掉 Codex 发来的 ChatGPT 令牌，换成网关 key 再转发，ChatGPT 令牌不会离开本机。
- 它还会把网关的 `/v1/models` 转成 Codex 认识的模型目录格式。
- 网关 key 存在 **Windows 凭据管理器**里，不写进任何文件。

## 安装

1. 完全退出 Codex Desktop（包括系统托盘）。
2. 双击 `install.cmd`，或者在 PowerShell 里运行：
   ```powershell
   .\install.ps1 -Upstream https://your-gateway.example.com/v1
   ```
   不加 `-Upstream` 的话，脚本会问你网关地址。

脚本会依次：

1. 找 Python 3.9+（没有就提示用 winget 装）。
2. 把 relay 装到 `%USERPROFILE%\.codex\magpie-relay\`，并从本机 Codex 的 `models_cache.json` 生成模型模板 `templates.json`。
3. 把网关 key 存进凭据管理器（目标名 `magpie-api-key`）。如果检测到用户环境变量 `MAGPIE_API_KEY`，会问你要不要导入。
4. 注册登录时自启动的计划任务。
5. 启动 relay 并自检：拉一次模型列表，做一次真实对话。**自检没通过就不会改 `config.toml`。**
6. 备份并修改 `config.toml`。
7. 用 `codex app-server` 检查：账号仍是 ChatGPT，模型列表来自网关。
8. 安装 `codex-mode` 命令（见下文）。

> **第一次安装要在 Codex 还没接到网关之前运行。** 模板是从 Codex 下载的官方模型目录里提取的；relay 开始提供模型列表后，Codex 的缓存会被覆盖。如果脚本提示无法生成模板，暂时删掉 `config.toml` 里的 `model_provider`，打开一次 Codex Desktop，再重新运行 install。

常用参数：

| 参数 | 作用 |
|---|---|
| `-Upstream https://.../v1` | 网关地址（默认沿用已有的 `relay.json`，没有就询问） |
| `-Model auto/gpt-6.1-terra` | 默认模型（默认沿用当前 config 里的模型） |
| `-ReasoningEffort high` | 推理强度（默认沿用当前值） |
| `-SkipConfig` | 只装好并启动 relay，不切换 Codex 配置 |
| `-SkipChatTest` | 跳过自检里的真实对话 |
| `-ReplaceKey` | 重新输入网关 key |
| `-Port 18765` | relay 端口 |
| `-PythonPath C:\...\python.exe` | 指定 Python |
| `-Force` | 跳过“Codex 正在运行”之类的确认 |

## OpenAI 额度用完时：`codex-mode`

Codex Desktop 会在 **ChatGPT 账号**额度用完时直接拦截发送，不管请求实际发到哪个 provider。`codex-mode` 用来在两种登录模式之间切换：

| 命令 | 作用 |
|---|---|
| `codex-mode` / `codex-mode status` | 查看当前模式、relay 是否在运行 |
| `codex-mode magpie` | 换成占位 API key 登录，Desktop 不再按 ChatGPT 额度拦截；**这期间 ChatGPT 账号功能不可用** |
| `codex-mode chatgpt` | 恢复保存的 ChatGPT 登录 |
| `codex-mode refresh` | magpie 模式下重新拉取网关模型列表 |

可选参数：`-Force` 跳过确认，`-NoRestart` 切换后不自动重新打开 Desktop。

- 切换前会先保存当前的 ChatGPT 登录（`magpie-relay\auth.chatgpt.json`），不会调用 `codex logout`，令牌不会被注销。
- Desktop 开着时会先问你，再关掉它（缩到托盘关不掉时会再问一次是否强制结束）、切换、重新打开。
- **不要在 Codex Desktop 自带的终端里运行 `codex-mode`**，它会把 Desktop 连同这个终端一起关掉。请用独立的 PowerShell 或命令提示符窗口。
- magpie 模式下 Codex 不会自己拉网关的模型列表，所以会用 `model_catalog_json` 指向一份本地列表。
- magpie 模式下重新运行 install 会去掉这一行，之后再运行一次 `codex-mode magpie` 即可。
- 在 magpie 模式下待太久，保存的 ChatGPT 令牌可能过期，切回去后在 Desktop 里重新登录一次即可。
- 命令装在 `%LOCALAPPDATA%\Microsoft\WindowsApps\codex-mode.cmd`（这个目录默认在 PATH 里）。如果找不到命令，直接运行 `%USERPROFILE%\.codex\magpie-relay\codex-mode.cmd`。

## 卸载

运行 `%USERPROFILE%\.codex\magpie-relay\uninstall.cmd`（或这里的 `uninstall.cmd`）。

- 如果当前是 magpie 模式，会先恢复 ChatGPT 登录（需要先完全退出 Desktop）。
- 默认只把 install 改过的 `model` / `model_provider` / `model_reasoning_effort` / `model_catalog_json` / `openai_base_url` 和 `[model_providers.magpie]` 恢复成安装前的原值，其余设置保持当前状态。

| 参数 | 作用 |
|---|---|
| `-RestoreBackup` | 整份恢复第一次安装前的 config.toml 备份 |
| `-DeleteKey` / `-KeepKey` | 删除 / 保留凭据管理器里的 `magpie-api-key`（不加就会询问） |
| `-KeepConfig` | 不动 config.toml |
| `-KeepFiles` | 保留 magpie-relay 目录（含日志） |

## 排查

- 日志：`%USERPROFILE%\.codex\magpie-relay\relay.log`
- 健康检查：`curl.exe http://127.0.0.1:18765/__relay/health`
- 计划任务名：`Codex magpie relay`（登录时启动，每 5 分钟拉起一次挂掉的 relay）

## 已知限制

- 非 GPT 模型（Claude、Cursor 等）套用的是 GPT 的模板，能不能正常用取决于网关。
- 没有推理档位的模型会被标成 `medium`，个别模型可能因此报错。
- `templates.json` 含有 OpenAI 的模型指令，只在本机生成，**不要上传到公开仓库**。

## 安全

relay 只监听 `127.0.0.1`，但**本机任何程序都能通过它使用你的网关额度**。不要把它暴露到局域网，也不要让别的电脑连这台电脑的 relay。
