#!/bin/bash
# magpie-codex-router uninstaller for macOS.
#
# Usage: ./uninstall.sh [--purge] [--purge-key]
#   --purge      also delete ~/.codex/magpie-relay (templates, logs, saved ChatGPT login)
#   --purge-key  also delete the gateway key from the Keychain
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
DIR="$CODEX_HOME/magpie-relay"
CONFIG="$CODEX_HOME/config.toml"
LABEL="${MAGPIE_RELAY_LABEL:-xyz.magpie.codex-relay}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SERVICE="${MAGPIE_KEYCHAIN_SERVICE:-magpie-api-key}"
BIN_DIR="${MAGPIE_BIN_DIR:-$HOME/.local/bin}"
PY=/usr/bin/python3
APP="${CODEX_MODE_APP:-ChatGPT}"

PURGE=""; PURGE_KEY=""
for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    --purge-key) PURGE_KEY=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "未知参数：$a" >&2; exit 2 ;;
  esac
done

# 1. If codex-mode left a placeholder API-key login, restore the ChatGPT login.
if [ -f "$CODEX_HOME/auth.json" ] && [ -f "$DIR/auth.chatgpt.json" ]; then
  mode=$($PY -I -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("auth_mode",""))
except Exception: print("")' "$CODEX_HOME/auth.json")
  if [ "$mode" = apikey ]; then
    if pgrep -qf "/Applications/${APP}.app/Contents/MacOS/${APP}"; then
      echo "请先完全退出 Codex Desktop 再运行（需要恢复 ChatGPT 登录）。" >&2; exit 1
    fi
    cp -p "$DIR/auth.chatgpt.json" "$CODEX_HOME/auth.json"
    chmod 600 "$CODEX_HOME/auth.json"
    echo "已恢复 ChatGPT 登录。"
  fi
fi

# 2. Stop and remove the relay LaunchAgent.
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST"
echo "已停止并移除 LaunchAgent。"

# 3. Remove the magpie provider from config.toml (after a backup).
if [ -f "$CONFIG" ]; then
  BACKUP="$CONFIG.bak-magpie-uninstall-$(date +%Y%m%d%H%M%S)"
  cp -p "$CONFIG" "$BACKUP"
  $PY -I - "$CONFIG" <<'PY'
import re, sys
path = sys.argv[1]
lines = open(path).read().split("\n")
out, skipping, in_top = [], False, True
for l in lines:
    m = re.match(r"\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*$", l)
    if m:
        in_top = False
        name = m.group(1).replace('"', "")
        skipping = name == "model_providers.magpie" or name.startswith("model_providers.magpie.")
    if skipping:
        continue
    if in_top and re.match(r'\s*model_provider\s*=\s*"magpie"', l):
        continue
    if in_top and re.match(r"\s*model_catalog_json\s*=.*magpie-relay", l):
        continue
    out.append(l)
open(path, "w").write("\n".join(out))
PY
  echo "已从 config.toml 移除 magpie provider（备份：${BACKUP}）。"
  model=$(grep -m1 -E '^model *=' "$CONFIG" || true)
  [ -n "$model" ] && echo "注意：当前 $model 可能是网关专用的模型 ID，请在 Codex 里换回官方模型。"
fi

# 4. Remove the codex-mode command.
if [ -L "$BIN_DIR/codex-mode" ]; then rm -f "$BIN_DIR/codex-mode"; fi

if [ -n "$PURGE" ]; then rm -rf "$DIR"; echo "已删除 ${DIR}。"; fi
if [ -n "$PURGE_KEY" ]; then
  security delete-generic-password -a "$USER" -s "$SERVICE" >/dev/null 2>&1 \
    && echo "已从 Keychain 删除网关 key。" || echo "Keychain 里没有找到网关 key。"
fi
echo "卸载完成。请完全退出并重新打开 Codex Desktop。"
