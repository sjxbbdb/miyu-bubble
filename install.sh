#!/usr/bin/env bash
# ==============================================================================
#  miyu-bubble 安装脚本
#
#  做四件事：
#    1. 拷脚本到 ~/
#    2. 拷 systemd 用户服务到 ~/.config/systemd/user/
#    3. 检查依赖（miyu / notify-send / 会话库 / 记忆库）
#    4. enable --now
# ==============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SVC_DIR="$HOME/.config/systemd/user"

say()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✅\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m⚠️\033[0m  %s\n' "$*"; }
die()  { printf '  \033[1;31m❌\033[0m %s\n' "$*" >&2; exit 1; }

say "── 1/4 检查依赖 ─────────────────────────────"

command -v miyu >/dev/null 2>&1 \
  && ok "miyu $(miyu --version 2>/dev/null | head -1 | awk '{print $2}')" \
  || die "找不到 miyu。先装 https://github.com/SHORiN-KiWATA/miyu-agent"

command -v notify-send >/dev/null 2>&1 \
  && ok "notify-send" \
  || warn "没有 notify-send，消息只会进会话历史，不会弹通知"

command -v python3 >/dev/null 2>&1 && ok "python3" || die "需要 python3"

CONV_DB="$HOME/.miyu/home/$(id -un)/conversation.db"
MEM_DB="$HOME/.miyu/personas/default/memory/memory.db"

[ -f "$CONV_DB" ] && ok "会话库 $CONV_DB" || die "找不到会话库，你还没跟 miyu 说过话？"
[ -f "$MEM_DB" ]  && ok "记忆库 $MEM_DB"  || warn "找不到记忆库，只能注入时间（记忆系统可能没开）"

# 至少要有一条会话
n=$(python3 -c "
import sqlite3
con = sqlite3.connect('file:$CONV_DB?mode=ro', uri=True)
print(con.execute('select count(*) from turns').fetchone()[0])
" 2>/dev/null || echo 0)
[ "$n" -gt 0 ] && ok "会话里有 $n 轮对话" || warn "会话是空的，第一次冒泡可能没什么好说的"

say ""
say "── 2/4 安装脚本 ─────────────────────────────"
install -m755 "$HERE/bin/miyu-bubble.sh"      "$HOME/miyu-bubble.sh"
ok "~/miyu-bubble.sh"
install -m755 "$HERE/bin/miyu-bubble-ctl.sh"  "$HOME/miyu-bubble-ctl.sh"
ok "~/miyu-bubble-ctl.sh"

say ""
say "── 3/4 安装 systemd 用户服务 ────────────────"
mkdir -p "$SVC_DIR"
install -m644 "$HERE/systemd/miyu-bubble.service" "$SVC_DIR/miyu-bubble.service"
ok "$SVC_DIR/miyu-bubble.service"

# 把服务里的 XDG_RUNTIME_DIR 对齐到实际用户（模板里写的是 1000）
if [ "$(id -u)" != "1000" ]; then
  sed -i "s|/run/user/1000|/run/user/$(id -u)|g" "$SVC_DIR/miyu-bubble.service"
  ok "修正 XDG_RUNTIME_DIR 为 /run/user/$(id -u)"
fi

systemctl --user daemon-reload
ok "daemon-reload"

say ""
say "── 4/4 启动 ─────────────────────────────────"
systemctl --user enable --now miyu-bubble.service >/dev/null 2>&1
sleep 2

if systemctl --user is-active --quiet miyu-bubble.service; then
  ok "服务运行中（开机自启已开）"
  base=$(systemctl --user show miyu-bubble.service -p Environment --value | tr ' ' '\n' | grep MIYU_BUBBLE_BASE | cut -d= -f2)
  base=${base:-2700}
  say ""
  say "  基准间隔 ${base}s ($((base/60)) 分钟) × 随机 [0.5, 2.0]"
  say "  实际落在 $((base/2/60)) ~ $((base*2/60)) 分钟"
else
  die "服务没起来，看 journalctl --user -u miyu-bubble -n 30"
fi

cat <<EOF

$(say "装好了。")

  想立刻看一条：  ~/miyu-bubble-ctl.sh now
  看状态：        ~/miyu-bubble-ctl.sh status
  静音：          ~/miyu-bubble-ctl.sh pause

日志：~/.miyu/cache/logs/bubble.log

EOF
