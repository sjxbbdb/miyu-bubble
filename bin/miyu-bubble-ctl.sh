#!/usr/bin/env bash
# ==============================================================================
#  miyu-bubble-ctl.sh — 控制「小鱼主动找你」
#
#  用法:
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

  pause)
    touch "$OFF"
    echo "⏸  已静音 —— 小鱼不会再主动说话（服务仍在跑）"
    ;;

  resume)
    rm -f "$OFF"
    echo "▶  已恢复"
    ;;

  now)
    echo "立刻触发一次（等 miyu 回话，约 5-40 秒）..."
    nohup bash -c '
      source <(sed -n "/^idle_seconds()/,/^}/p" '"$SCRIPT"')
      source <(sed -n "/^build_context()/,/^}/p" '"$SCRIPT"')
      CONV_DB="$HOME/.miyu/home/$(id -un)/conversation.db"
      MEM_DB="$HOME/.miyu/personas/default/memory/memory.db"
      DIARY_N=8; FACT_N=8
      idle=$(idle_seconds); ctx=$(build_context)
      prompt="（这是一条后台触发的自检提示，不是对方发给你的消息。对方已经 ${idle} 秒没有新的输入了。）

${ctx}

现在请你主动找对方说一句话。要求：
1. 用你自己的语气，自然，像平时聊天那样
2. 可以顺着最近聊的话题跟进，也可以只是打个招呼、说点你想到的
3. 适度询问 —— 但不要追问、不要催活、不要提任何要求
4. 结合上面给出的当前时间，别说成不合时宜的话
5. 一到两句话，简短，别长篇大论
6. 直接输出你要说的话本身，不要写「我来找你了」这类旁白"
      raw=$(miyu ask -c --output-format json --timeout 180 "$prompt" 2>/dev/null)
      msg=$(printf "%s" "$raw" | python3 -c "import json,sys
try: print(json.loads(sys.stdin.read()).get(\"text\",\"\") or \"\")
except: print(\"\")")
      [ -n "$msg" ] && notify-send -a "小鱼" -i face-smile "小鱼找你" "$msg"
      printf "[%s] 手动触发：%s\n" "$(date "+%m-%d %H:%M:%S")" "$msg" >> '"$LOG"'
    ' > /dev/null 2>&1 &
    echo "  已发到后台，等通知弹出来"
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
