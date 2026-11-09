# magpie-codex-router · macOS

让 Codex（Desktop 和 CLI）**保持 ChatGPT 登录**，同时把**模型请求和模型列表**交给你自己的网关（任何兼容 OpenAI Responses API、用自己 key 鉴权的网关）。

## 为什么需要它

直接在 Codex 里配一个自定义 provider 会遇到几个问题：

| 做法 | 问题 |
|---|---|
| 自定义 provider，用 `env_key` / `experimental_bearer_token` / `auth` 命令带网关 key | Codex 认为“没有账号”，Desktop **每次启动都会走首次引导**，ChatGPT 相关功能也没了 |
| `openai_base_url` 指向网关 | Codex 会把 **ChatGPT 登录令牌发给网关**，既泄露令牌，网关也不认（401） |
| 网关的 `/v1/models` | 是 OpenAI 列表格式，Codex 读不了，模型选择器里还是官方模型 |

这个项目的做法：在本机 `127.0.0.1` 跑一个很小的 relay。

```
Codex ──(ChatGPT 令牌)──> relay 127.0.0.1:18765 ──(网关 key)──> 你的网关
                          │ 丢掉 ChatGPT 令牌和账号头
                          │ 从 Keychain 取网关 key
                          └ 把 /v1/models 转成 Codex 的模型目录格式
```

- Codex 使用 `requires_openai_auth = true` 的自定义 provider，所以仍然是 ChatGPT 登录状态，不会弹引导。
- ChatGPT 令牌**不会离开本机**；网关 key 只保存在 Keychain 里，不写进任何文件。
- 只用系统自带的 `/usr/bin/python3` 标准库，无第三方依赖。

## 安装

```bash
git clone https://github.com/TooonyChen/magpie-codex-router.git
cd magpie-codex-router/macOS
./install.sh --upstream https://your-gateway.example.com/v1 --model <网关里的模型 ID>
```

两个参数都可以不填，脚本会问你。脚本会：

1. 检查环境（macOS、`/usr/bin/python3`、已有 `~/.codex/config.toml`）。
2. 如果 Keychain 里还没有，提示你输入网关 key（不显示、不进命令历史），保存为 service `magpie-api-key`。
3. 把 relay 和 `codex-mode` 装到 `~/.codex/magpie-relay/`，写入 `relay.json`（网关地址、端口）。
4. 从本机 Codex 的 `models_cache.json` 生成模型模板 `templates.json`（见下文）。
5. 注册 LaunchAgent `xyz.magpie.codex-relay`，登录时自动启动、挂了自动重启，并自检一次。
6. **先备份**再修改 `~/.codex/config.toml`：设置 `model_provider = "magpie"` 和 `[model_providers.magpie]`，其他配置不动。
7. 把 `codex-mode` 链接到 `~/.local/bin/`。

装完后**完全退出并重新打开 Codex Desktop**。可以重复运行 `install.sh` 来更新。

> **注意：第一次安装要在 Codex 还没接到网关之前运行。** 模板是从 Codex 下载的官方模型目录里提取的；一旦 relay 开始提供模型列表，Codex 的缓存就会被覆盖。如果脚本提示缓存里没有官方模型，暂时删掉 `config.toml` 里的 `model_provider`，打开一次 Codex Desktop，再重新运行。

## OpenAI 额度用完时：`codex-mode`

新版 Codex Desktop 会在 **ChatGPT 账号**额度用完时直接拦截发送，不管请求实际发到哪个 provider。`codex-mode` 用来在两种模式之间切换：

| 命令 | 作用 |
|---|---|
| `codex-mode` / `codex-mode status` | 查看当前模式、relay 是否在运行 |
| `codex-mode magpie` | 换成占位 API key 登录，Desktop 不再按 ChatGPT 额度拦截；**这期间 ChatGPT 账号功能不可用** |
| `codex-mode chatgpt` | 恢复保存的 ChatGPT 登录 |
| `codex-mode refresh` | magpie 模式下重新拉取网关模型列表 |

- 切换前会先保存当前的 ChatGPT 登录（`~/.codex/magpie-relay/auth.chatgpt.json`），不会调用 `codex logout`，所以令牌不会被注销。
- Desktop 开着时会先问你，再退出它、切换、重新打开。
- magpie 模式下 Codex 不会自己拉网关的模型列表，所以会用 `model_catalog_json` 指向一份本地列表。
- 在 magpie 模式下待太久，保存的 ChatGPT 令牌可能过期，切回去后在 Desktop 里重新登录一次即可。

## 文件

安装后都在 `~/.codex/magpie-relay/`：

| 文件 | 说明 |
|---|---|
| `relay.py` | relay 本体 |
| `relay.json` | 网关地址、端口、Keychain service（不含 key） |
| `templates.json` | 从本机 Codex 缓存提取的官方模型条目，用来给网关的模型套参数。**不要上传到公开仓库**（含 OpenAI 的模型指令） |
| `relay.log` | relay 日志，出问题先看这里 |
| `codex-mode` | 模式切换脚本 |
| `catalog.json` / `auth.chatgpt.json` | `codex-mode` 生成的模型列表和保存的 ChatGPT 登录 |

## 模型列表是怎么转换的

对网关返回的每个模型，取 `/` 后面的部分去匹配官方模型（例如 `auto/gpt-6.1-terra` → `gpt-6.1-terra`），匹配不到就用 `gpt-5.6-sol` 的模板。然后用网关的数据覆盖：ID、显示名（`magpie_label` 或 `display_name`）、上下文窗口、输入类型、推理档位、速度档位。Codex 0.150 之前的版本只会拿到它认识的推理档位。

## 已知限制

- **非 GPT 模型**（Claude、Cursor 等）用的是 GPT 的模板（工具模式、指令），能不能正常用取决于网关。
- 没有推理档位的模型会被标成 `medium`，个别模型可能因此报错。
- 旧版 Codex CLI（例如 0.135）读不了新格式的模型列表：chatgpt 模式下会退回内置列表（请求照常走网关），magpie 模式下会启动失败。升级即可：`brew upgrade --cask codex`。
- Codex Desktop 更新后，引导、额度检查等行为可能会变。

## 安全

- relay 只监听 `127.0.0.1`，但**本机任何程序都能通过它用你的网关额度**。不要把它暴露到局域网，也不要让别的电脑连这台电脑的 relay。
- 网关最好用 https；用 http 时 key 会明文传输。
- 想检查令牌没有外泄：`relay.log` 只记录方法、路径和状态码，不记录请求头和内容。

## 卸载

```bash
./uninstall.sh              # 停止 relay、移除 LaunchAgent、从 config.toml 去掉 provider
./uninstall.sh --purge      # 同时删除 ~/.codex/magpie-relay
./uninstall.sh --purge-key  # 同时删除 Keychain 里的网关 key
```

如果当前处于 magpie 模式，卸载时会先恢复 ChatGPT 登录（需要先退出 Desktop）。卸载后记得在 Codex 里把模型换回官方模型。
