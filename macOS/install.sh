#!/bin/bash
# magpie-codex-router installer for macOS.
#
# Sets up Codex (Desktop and CLI) so it stays logged in with ChatGPT while
# model requests and the model list come from your gateway:
#   1. stores the gateway key in the macOS Keychain (never in a file)
#   2. captures Codex model templates from your local Codex cache
#   3. installs the relay as a LaunchAgent on 127.0.0.1
#   4. points ~/.codex/config.toml at the relay (after a backup)
#   5. installs the `codex-mode` command
#
# Usage: ./install.sh [--upstream https://gateway.example.com/v1] [--model MODEL_ID]
# Safe to re-run: it updates an existing install in place.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
DIR="$CODEX_HOME/magpie-relay"
CONFIG="$CODEX_HOME/config.toml"
LABEL="${MAGPIE_RELAY_LABEL:-xyz.magpie.codex-relay}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT="${MAGPIE_RELAY_PORT:-18765}"
SERVICE="${MAGPIE_KEYCHAIN_SERVICE:-magpie-api-key}"
BIN_DIR="${MAGPIE_BIN_DIR:-$HOME/.local/bin}"
PY=/usr/bin/python3

UPSTREAM=""
MODEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --upstream) UPSTREAM="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
die() { echo "错误：$*" >&2; exit 1; }

# ---------------------------------------------------------------- checks
step "检查环境"
[ "$(uname -s)" = Darwin ] || die "这个脚本只支持 macOS。"
$PY -c 'import sys; assert sys.version_info >= (3, 8)' 2>/dev/null \
  || die "需要系统自带的 /usr/bin/python3（3.8+）。可以先运行 xcode-select --install。"
[ -f "$CONFIG" ] || die "找不到 ${CONFIG}。请先打开一次 Codex Desktop 或运行一次 codex。"
for f in relay.py codex-mode; do [ -f "$SRC/$f" ] || die "缺少 $SRC/$f"; done
echo "OK"

# ---------------------------------------------------------------- upstream
if [ -z "$UPSTREAM" ] && [ -f "$DIR/relay.json" ]; then
  UPSTREAM=$($PY -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("upstream",""))' "$DIR/relay.json")
  [ -n "$UPSTREAM" ] && echo "沿用已有网关地址：$UPSTREAM"
fi
if [ -z "$UPSTREAM" ]; then
  read -r -p "网关 base URL（例如 https://gateway.example.com/v1）：" UPSTREAM
fi
UPSTREAM="${UPSTREAM%/}"
[[ "$UPSTREAM" =~ ^https?://[^/]+ ]] || die "网关地址无效：$UPSTREAM"
[[ "$UPSTREAM" =~ ^https:// ]] || echo "警告：网关不是 https，key 会以明文传输。"

# ---------------------------------------------------------------- keychain
step "Keychain 中的网关 key（service: ${SERVICE}）"
if security find-generic-password -a "$USER" -s "$SERVICE" >/dev/null 2>&1; then
  echo "已存在，沿用。（要更换：security add-generic-password -U -a \"\$USER\" -s $SERVICE -w）"
else
  echo "接下来输入网关 key，输入时不会显示，需要输入两次。"
  security add-generic-password -U -a "$USER" -s "$SERVICE" -w \
    || die "保存 key 失败。"
fi

# ---------------------------------------------------------------- files
step "安装 relay 到 $DIR"
mkdir -p "$DIR"; chmod 700 "$DIR"
install -m 700 "$SRC/relay.py" "$DIR/relay.py"
install -m 700 "$SRC/codex-mode" "$DIR/codex-mode"
$PY -I - "$DIR/relay.json" "$UPSTREAM" "$PORT" "$SERVICE" "$USER" <<'PY'
import json, os, sys
p, upstream, port, service, account = sys.argv[1:]
with open(p + ".tmp", "w") as f:
    json.dump({"upstream": upstream, "port": int(port),
               "keychain_service": service, "keychain_account": account},
              f, indent=2)
os.chmod(p + ".tmp", 0o600)
os.replace(p + ".tmp", p)
PY
echo "OK"

# ---------------------------------------------------------------- templates
step "生成 Codex 模型模板"
if [ -s "$DIR/templates.json" ]; then
  echo "已存在 templates.json，沿用。"
else
  # Codex overwrites models_cache.json with whatever the relay serves, so the
  # official entries can only be captured before the relay is in use.
  $PY -I - "$CODEX_HOME/models_cache.json" "$DIR/templates.json" <<'PY' || exit 1
import json, os, sys
src, dst = sys.argv[1:]
try:
    d = json.load(open(src))
except Exception as e:
    sys.exit(f"错误：读不了 {src}（{e}）。请先在不经过网关的情况下打开一次 Codex，让它下载官方模型列表。")
models = [m for m in d.get("models", []) if "/" not in m.get("slug", "/")]
if not models:
    sys.exit("错误：Codex 缓存里没有官方模型（可能已经被网关的列表覆盖）。"
             "请暂时去掉 config.toml 里的 model_provider，打开一次 Codex Desktop，再重新运行本脚本。")
with open(dst + ".tmp", "w") as f:
    json.dump({"source_client_version": d.get("client_version"), "models": models}, f)
os.chmod(dst + ".tmp", 0o600)
os.replace(dst + ".tmp", dst)
print(f"已从 Codex {d.get('client_version')} 的缓存保存 {len(models)} 个模板")
PY
fi

# ---------------------------------------------------------------- launchd
step "注册 LaunchAgent（${LABEL}）"
mkdir -p "$(dirname "$PLIST")"
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$PY</string><string>-I</string><string>$DIR/relay.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardErrorPath</key><string>$DIR/relay.log</string>
  <key>StandardOutPath</key><string>$DIR/relay.log</string>
</dict></plist>
EOF
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST"

ok=""
for _ in $(seq 1 20); do
  if curl -sf --max-time 10 -o /dev/null -H 'Authorization: Bearer placeholder' \
       "http://127.0.0.1:$PORT/v1/models"; then ok=1; break; fi
  sleep 0.5
done
[ -n "$ok" ] || die "relay 没有正常响应。看日志：$DIR/relay.log（macOS 可能弹出了 Keychain 授权，请点“始终允许”后重新运行）"
echo "relay 正常，网关返回了模型列表。"

# ---------------------------------------------------------------- config.toml
step "修改 $CONFIG"
BACKUP="$CONFIG.bak-magpie-$(date +%Y%m%d%H%M%S)"
cp -p "$CONFIG" "$BACKUP"
echo "已备份到 $BACKUP"
if [ -z "$MODEL" ]; then
  current=$(grep -m1 -E '^model *=' "$CONFIG" | sed -E 's/^model *= *"?([^"]*)"?.*/\1/' || true)
  read -r -p "默认模型 ID（网关里的 ID，例如 auto/gpt-6.1-terra；直接回车保留当前的 ${current:-<未设置>}）：" MODEL
fi
$PY -I - "$CONFIG" "$PORT" "$MODEL" <<'PY'
import re, sys
path, port, model = sys.argv[1:]
lines = open(path).read().split("\n")

first_table = next((i for i, l in enumerate(lines) if re.match(r"\s*\[", l)), len(lines))
top, rest = lines[:first_table], lines[first_table:]

def is_key(line, key):
    return re.match(rf"\s*{re.escape(key)}\s*=", line) is not None

top = [l for l in top if not is_key(l, "model_provider")]
if model:
    top = [l for l in top if not is_key(l, "model")]
    top.insert(0, f'model = "{model}"')
idx = next((i + 1 for i, l in enumerate(top) if is_key(l, "model")), 0)
top.insert(idx, 'model_provider = "magpie"')
if any(is_key(l, "openai_base_url") for l in top):
    print("警告：config.toml 里有 openai_base_url。它会让内置 provider 把 ChatGPT 令牌发到那个地址，"
          "如果它指向网关，请删掉。")

# Drop any existing [model_providers.magpie] table and its sub-tables.
out, skipping = [], False
for l in rest:
    m = re.match(r"\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*$", l)
    if m:
        name = m.group(1).replace('"', "")
        skipping = name == "model_providers.magpie" or name.startswith("model_providers.magpie.")
    if not skipping:
        out.append(l)
while out and out[-1].strip() == "":
    out.pop()

provider = [
    "",
    "[model_providers.magpie]",
    'name = "magpie"',
    "# magpie-codex-router relay: swaps the ChatGPT token for the gateway key",
    "# from Keychain. See ~/.codex/magpie-relay/relay.json for the gateway URL.",
    f'base_url = "http://127.0.0.1:{port}/v1"',
    'wire_api = "responses"',
    "requires_openai_auth = true",
    "supports_websockets = false",
    "",
]
open(path, "w").write("\n".join(top + out + provider))
PY
grep -E '^(model|model_provider) *=' "$CONFIG" | head -2

# ---------------------------------------------------------------- codex-mode
step "安装 codex-mode 命令"
mkdir -p "$BIN_DIR"
ln -sf "$DIR/codex-mode" "$BIN_DIR/codex-mode"
echo "已链接到 $BIN_DIR/codex-mode"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "注意：$BIN_DIR 不在 PATH 里，请把它加进 ~/.zshrc。" ;; esac

step "完成"
cat <<EOF
- 完全退出 Codex Desktop 再重新打开，模型选择器里就是网关的模型。
- relay 日志：$DIR/relay.log
- OpenAI 额度用完、Desktop 拦截发送时：codex-mode magpie；额度恢复后：codex-mode chatgpt
- 卸载：$SRC/uninstall.sh
EOF
