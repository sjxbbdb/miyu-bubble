#!/usr/bin/env bash
# ==============================================================================
#  miyu-bubble-ctl.sh — 控制「小鱼主动找你」
#
#  用法:
#    miyu-bubble-ctl.sh verify    三层验证：服务 → 触发记录 → 消息进没进会话
#    miyu-bubble-ctl.sh status    看状态、当前间隔、最近说了什么
#    miyu-bubble-ctl.sh pause     静音（服务还在跑，但不再说话）
#    miyu-bubble-ctl.sh resume    恢复
#    miyu-bubble-ctl.sh now       立刻触发一次（不等掷骰子）
#    miyu-bubble-ctl.sh log       看完整日志
#    miyu-bubble-ctl.sh stop      彻底停掉服务
#    miyu-bubble-ctl.sh start     重新启动服务
# ==============================================================================
set -uo pipefail

SVC=miyu-bubble.service
SCRIPT="$HOME/miyu-bubble.sh"
LOG="$HOME/.miyu/cache/logs/bubble.log"
OFF="$HOME/.miyu/bubble-off"

case "${1:-status}" in
  status)
    echo "── 服务 ──"
    printf "  运行状态: %s\n" "$(systemctl --user is-active $SVC 2>/dev/null)"
    printf "  开机自启: %s\n" "$(systemctl --user is-enabled $SVC 2>/dev/null)"
    if [ -e "$OFF" ]; then
      echo "  静音开关: ⏸  已静音（$OFF 存在）"
    else
      echo "  静音开关: ▶  正常说话"
    fi
    echo
    echo "── 当前配置 ──"
    base=$(systemctl --user show $SVC -p Environment --value 2>/dev/null | tr ' ' '\n' | grep MIYU_BUBBLE_BASE | cut -d= -f2)
    base=${base:-2700}
    echo "  基准间隔: ${base}s ($((base/60)) 分钟) × 随机 [0.5, 2.0]"
    echo "  实际落在: $((base/2/60)) ~ $((base*2/60)) 分钟"
    echo
    echo "── 最近 5 条 ──"
    [ -f "$LOG" ] && grep '生成' "$LOG" | tail -5 | sed 's/^/  /' || echo "  （还没有记录）"
    ;;

  verify)
    # 三层验证：服务 → 触发记录 → 消息真的进了小鱼的会话
    DB="$HOME/.miyu/home/$(id -un)/conversation.db"

    echo "── 第 1 层：服务在不在 ──"
    a=$(systemctl --user is-active "$SVC" 2>/dev/null)
    e=$(systemctl --user is-enabled "$SVC" 2>/dev/null)
    printf "  运行状态: %s    开机自启: %s\n" "$a" "$e"
    if [ "$a" != "active" ]; then
      echo "  ❌ 服务没跑。systemctl --user start $SVC"
      exit 1
    fi
    # 能看到 sleep 才说明循环真的在等，而不是卡住了
    pid=$(systemctl --user show "$SVC" -p MainPID --value)
    if command -v pstree >/dev/null 2>&1; then
      pstree -p "$pid" 2>/dev/null | head -2 | sed 's/^/  /'
    else
      ps --ppid "$pid" -o pid,cmd --no-headers 2>/dev/null | sed 's/^/  /'
    fi

    echo
    echo "── 第 2 层：触发记录 ──"
    if [ -f "$LOG" ]; then
      printf "  日志行数: %s   最后一行: %s\n" \
        "$(wc -l < "$LOG")" "$(tail -1 "$LOG" | cut -c1-60)"
      echo "  最近 3 条冒泡:"
      grep '生成' "$LOG" | tail -3 | sed 's/^/    /' || echo "    （还没冒过泡）"
      # 撞车次数。注意 grep -c 匹配不到时会输出 "0" 并返回非零，
      # 别写成 `|| echo 0` —— 那样会得到 "0\n0" 两行的值，下面整数比较直接炸。
      cc=$(grep -c '撞车' "$LOG" 2>/dev/null)
      cc=${cc:-0}
      [ "$cc" -gt 0 ] && echo "  ℹ️  撞车 $cc 次 —— miyu 会排队，真实回复稍后覆写，不影响送达"
    else
      echo "  （日志还不存在 —— 还没到第一次触发）"
    fi

    echo
    echo "── 第 3 层：消息真的进小鱼的会话了吗 ──"
    python3 - "$DB" <<'PY'
import sqlite3, sys
con = sqlite3.connect(f'file:{sys.argv[1]}?mode=ro', uri=True)
n = con.execute("select count(*) from turns").fetchone()[0]
nours = con.execute(
    "select count(*) from turns where user_content like '%后台触发的自检提示%'").fetchone()[0]
print(f"  会话总轮数:       {n}")
print(f"  其中我们的冒泡:   {nours}")
if nours:
    row = con.execute(
        "select user_timestamp, assistant_content from turns "
        "where user_content like '%后台触发的自检提示%' order by seq desc limit 1").fetchone()
    print(f"  最近一次:         {row[0][:19]}")
    print(f"  小鱼当时回的是:   {str(row[1])[:90]}")
    print()
    print("  ✅ 数据链路完整：外部服务 → miyu ask -c → 会话库")
else:
    print()
    print("  ⚠️ 会话里还没有我们的冒泡记录。先跑一次： $0 now")
PY
    ;;

  pause)
    touch "$OFF"
    echo "⏸  已静音 —— 小鱼不会再主动说话（服务仍在跑）"
    ;;

  resume)
    rm -f "$OFF"
    echo "▶  已恢复"
    ;;

  now)
    # 只调主脚本的 --once，不再自己抄一份通知逻辑（两份代码必然漂移）
    echo "立刻触发一次（等小鱼回话，约 5-40 秒）..."
    "$SCRIPT" --once > /dev/null 2>&1 &
    echo "  已发到后台。通知带两个按钮："
    echo "    [去回她]  → 开一个终端接上对话"
    echo "    [知道了]  → 关掉"
    ;;

  log)
    [ -f "$LOG" ] && tail -40 "$LOG" || echo "（日志还不存在）"
    ;;

  stop)
    systemctl --user stop "$SVC" && echo "⏹  服务已停止"
    ;;

  start)
    systemctl --user start "$SVC" && echo "▶  服务已启动"
    ;;

  *)
    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
