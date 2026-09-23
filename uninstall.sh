#!/usr/bin/env bash
# ==============================================================================
#  miyu-bubble 卸载脚本
#
#  默认只移除程序与自启，保留日志和静音开关（方便你想再装回来）。
#  加 --purge 连日志一起清。
# ==============================================================================
set -uo pipefail

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

say() { printf '\033[1;36m%s\033[0m\n' "$*"; }
ok()  { printf '  \033[1;32m✅\033[0m %s\n' "$*"; }

say "停服务并取消自启"
systemctl --user disable --now miyu-bubble.service 2>/dev/null && ok "服务已停" || ok "服务本来就没跑"

say "移除文件"
rm -f "$HOME/.config/systemd/user/miyu-bubble.service" && ok "systemd 服务"
systemctl --user daemon-reload

rm -f "$HOME/miyu-bubble.sh" "$HOME/miyu-bubble-ctl.sh" && ok "两个脚本"

if [ "$PURGE" = "1" ]; then
  rm -f "$HOME/.miyu/cache/logs/bubble.log" "$HOME/.miyu/bubble-off"
  ok "日志与静音开关已清除"
else
  say ""
  say "保留了（想再装回来不用重配）："
  say "  ~/.miyu/cache/logs/bubble.log"
  say "  ~/.miyu/bubble-off （如果存在）"
  say ""
  say "要连这些一起清就加 --purge"
fi

say ""
say "卸载完成。miyu 本体没动。"
