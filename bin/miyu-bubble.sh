#!/usr/bin/env bash
# ==============================================================================
#  miyu-bubble.sh — 让「小鱼」在自己想说话的时候主动找你
#
#  ── 设计（按用户 2026-09-23 的要求）──────────────────────────────────────
#    · 不用固定定时器：每轮「基准值 × 随机数」掷一次骰子，间隔自然不均匀
#    · 不做硬限制：没有每日上限、没有安静时段（后期再考虑加判断）
#    · 直接调用记忆与日记：把 miyu 的 facts / episodes 喂进提示词
#    · 带上当前时间：让它知道「现在几点」，说话才自然
#    · 适度询问：提示词里明确禁止催活、追问、提要求
#
#  ── 机制 ────────────────────────────────────────────────────────────────
#    1. 掷骰子 → interval = BASE × random(JITTER_MIN, JITTER_MAX)
#    2. sleep(interval)
#    3. 查真实空闲时长（miyu 会话库里最后一次用户输入距今多久）
#       · 空闲 < interval  → 对方一直在聊，重掷，不打扰
#       · 空闲 ≥ interval  → 该说话了
#    4. 组装上下文：近期日记 + 高权重事实 + 当前时间
#    5. miyu ask -c "<提示词>"   → 带着完整会话上下文生成一句话
#    6. notify-send 投递到桌面（同时这句话也进了会话历史）
#
#  ── 控制 ────────────────────────────────────────────────────────────────
#    静音：  touch ~/.miyu/bubble-off
#    恢复：  rm ~/.miyu/bubble-off
#    日志：  ~/.miyu/cache/logs/bubble.log
# ==============================================================================
set -uo pipefail

# ---- 可调参数 ----------------------------------------------------------------
BASE="${MIYU_BUBBLE_BASE:-2700}"       # 基准间隔（秒），默认 45 分钟
JITTER_MIN="${MIYU_BUBBLE_MIN:-0.5}"   # 随机下界
JITTER_MAX="${MIYU_BUBBLE_MAX:-2.0}"   # 随机上界

DIARY_N=8            # 喂几条近期日记
FACT_N=8             # 喂几条事实

# ---- 路径 --------------------------------------------------------------------
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
MIYU_HOME="$HOME/.miyu"
CONV_DB="$MIYU_HOME/home/$(id -un)/conversation.db"
MEM_DB="$MIYU_HOME/personas/default/memory/memory.db"
LOG_DIR="$MIYU_HOME/cache/logs"
LOG="$LOG_DIR/bubble.log"
OFF_SWITCH="$MIYU_HOME/bubble-off"

mkdir -p "$LOG_DIR"

log() { printf '[%s] %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# ==============================================================================
#  1. 掷骰子：基准 × 随机
# ==============================================================================
roll() {
    python3 -c "
import random, sys
base, lo, hi = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
print(int(base * random.uniform(lo, hi)))
" "$BASE" "$JITTER_MIN" "$JITTER_MAX"
}

# ==============================================================================
#  2. 真实空闲时长（秒）
# ==============================================================================
idle_seconds() {
    python3 - "$CONV_DB" <<'PY'
import sqlite3, sys, datetime
try:
    con = sqlite3.connect(f'file:{sys.argv[1]}?mode=ro', uri=True)
    row = con.execute("select max(user_timestamp) from turns").fetchone()
    if not row or not row[0]:
        print(0); raise SystemExit
    last = datetime.datetime.fromisoformat(row[0])
    if last.tzinfo is None:
        last = last.replace(tzinfo=datetime.timezone.utc)
    now = datetime.datetime.now(datetime.timezone.utc)
    print(int((now - last).total_seconds()))
except Exception:
    print(0)
PY
}

# ==============================================================================
#  3. 组装上下文：日记 + 事实 + 当前时间
# ==============================================================================
build_context() {
    python3 - "$MEM_DB" "$DIARY_N" "$FACT_N" <<'PY'
import sqlite3, sys, datetime

db, diary_n, fact_n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
con = sqlite3.connect(f'file:{db}?mode=ro', uri=True)

now = datetime.datetime.now()
weekday = "一二三四五六日"[now.weekday()]
hour = now.hour
if   5 <= hour < 11: period = "早上"
elif 11 <= hour < 14: period = "中午"
elif 14 <= hour < 18: period = "下午"
elif 18 <= hour < 23: period = "晚上"
else:                 period = "深夜"

out = []
out.append(f"现在是 {now.strftime('%Y-%m-%d %H:%M')}（周{weekday}，{period}）。")

# 近期日记
try:
    rows = con.execute(
        "select content from episodes where status='active' "
        "order by rowid desc limit ?", (diary_n,)).fetchall()
    if rows:
        out.append("\n【最近发生的事（你自己的日记，由近到远）】")
        for (c,) in rows:
            out.append("  · " + str(c).replace("\n", " ")[:300])
except Exception:
    pass

# 高权重事实
try:
    rows = con.execute(
        "select content from facts where status='active' "
        "order by strength desc, rowid desc limit ?", (fact_n,)).fetchall()
    if rows:
        out.append("\n【你记得的事】")
        for (c,) in rows:
            out.append("  · " + str(c).replace("\n", " ")[:200])
except Exception:
    pass

print("\n".join(out))
PY
}

# ==============================================================================
#  4. 主循环
# ==============================================================================
log "── 启动 ── 基准 ${BASE}s ×[${JITTER_MIN},${JITTER_MAX}]"

while true; do
    interval=$(roll)
    log "掷骰子 → ${interval}s（$(( interval / 60 )) 分钟）后检查"
    sleep "$interval"

    # 静音开关
    if [ -e "$OFF_SWITCH" ]; then
        log "已静音（存在 $OFF_SWITCH），跳过本轮"
        continue
    fi

    idle=$(idle_seconds)
    if [ "$idle" -lt "$interval" ]; then
        log "对方还在聊（空闲 ${idle}s < ${interval}s），重掷不打扰"
        continue
    fi

    # ---- 该说话了 ------------------------------------------------------------
    log "空闲 ${idle}s，触发"

    ctx=$(build_context)
    # 上下文取失败时不能装作没事——否则会拿一个空提示词去调，模型只能瞎编。
    # 这里降级成「只给时间」的最小上下文，并且留痕。
    if [ -z "$ctx" ]; then
        log "⚠️ 上下文组装为空（记忆库读不到？），降级为仅时间"
        ctx="现在是 $(date '+%Y-%m-%d %H:%M')。"
    fi

    prompt="（这是一条后台触发的自检提示，不是对方发给你的消息。对方已经 ${idle} 秒没有新的输入了。）

${ctx}

现在请你主动找对方说一句话。要求：
1. 用你自己的语气，自然，像平时聊天那样
2. 可以顺着最近聊的话题跟进，也可以只是打个招呼、说点你想到的
3. 适度询问 —— 但不要追问、不要催活、不要提任何要求
4. 结合上面给出的当前时间，别说成不合时宜的话
5. 一到两句话，简短，别长篇大论
6. 直接输出你要说的话本身，不要写「我来找你了」这类旁白，不要解释你在做什么"

    # ── 调 miyu ─────────────────────────────────────────────────────────────
    # 用 --output-format json：一行终态，text 字段是干净的回复正文，
    # 还附带 usage / context_tokens / elapsed_ms，可以顺手记进日志。
    # （text 模式下即使加 --quiet 也能用，但 json 更省心且信息更多。）
    raw=$(miyu ask -c --output-format json --timeout 180 "$prompt" 2>/dev/null)
    rc=$?

    if [ "$rc" -ne 0 ]; then
        log "⚠️ miyu 退出码 $rc，本轮放弃"
        continue
    fi

    msg=$(printf '%s' "$raw" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get('text', '') or '')
except Exception:
    print('')
" 2>/dev/null)

    if [ -z "$msg" ]; then
        log "⚠️ miyu 没返回内容，本轮放弃"
        continue
    fi

    # 用量顺手记一笔
    stats=$(printf '%s' "$raw" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    u = d.get('usage') or {}
    print(f\"{d.get('elapsed_ms',0)}ms  {u.get('total_tokens','?')} tokens  上下文 {d.get('context_tokens','?')}/{d.get('context_window','?')}\")
except Exception:
    print('')
" 2>/dev/null)

    log "生成（$stats）：$msg"

    notify-send -a "小鱼" -i face-smile \
        -h string:x-canonical-private-synchronous:miyu-bubble \
        "小鱼找你" "$msg" 2>/dev/null \
        && log "已投递通知" \
        || log "⚠️ 通知投递失败"
done
