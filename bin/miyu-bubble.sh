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

# ---- 参数 --------------------------------------------------------------------
#   (无参数)   常驻循环
#   --once     立刻跑一轮（跳过等待与空闲判定），给「手动触发」用
ONCE=0
FORCE=0
for a in "$@"; do
    case "$a" in
        --once) ONCE=1; FORCE=1 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
done

# ---- 可调参数 ----------------------------------------------------------------
BASE="${MIYU_BUBBLE_BASE:-2700}"       # 基准间隔（秒），默认 45 分钟
JITTER_MIN="${MIYU_BUBBLE_MIN:-0.5}"   # 随机下界
JITTER_MAX="${MIYU_BUBBLE_MAX:-2.0}"   # 随机上界

DIARY_N=8            # 喂几条近期日记
FACT_N=8             # 喂几条事实

# 目标会话。留空 = 用 -c（跟当前终端会话走）。
#
# ⚠️ 会话名是**按人格隔离**的（miyu 的 find_session_by_name 会带上 persona 条件），
#    所以「终端集成会话」这个名字只在 default 人格下能查到 —— 换人格后就查不到了。
#    而且 miyu 有条设计：normal 车道永不落进终端集成会话，每次开新 REPL 都会
#    新建一条会话，「当前会话」指针随之移动。
#
#    留空（默认）：跟着你当前所在的会话走 —— 消息一定送到你眼前，
#                  但上下文可能很薄（新会话没有历史）。
#    指定值：     钉死在一条会话上 —— 上下文完整，但你得自己保证会回去看。
#
#    取值形式：会话名（如「终端集成会话」）或 `miyu session list` 里的编号。
TARGET_SESSION="${MIYU_BUBBLE_SESSION:-}"
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
#
#  判据是「双方都停下来」而不是「用户停止说话」：
#    · user_timestamp       —— 用户最后一次开口
#    · assistant_timestamp  —— 小鱼最后一次说完
#  取两者较晚的那个。否则会出现：用户问完就走开，小鱼还在答，我们插进去撞车。
#
#  另外：如果有 turn 的 assistant_timestamp 为空，说明有一轮正在飞 ——
#  直接返回 0（等价于"刚刚还在活动"），本轮不打扰。
# ==============================================================================
idle_seconds() {
    python3 - "$CONV_DB" <<'PY'
import sqlite3, sys, datetime
try:
    con = sqlite3.connect(f'file:{sys.argv[1]}?mode=ro', uri=True)

    # 有在飞的回合 → 视为不空闲
    inflight = con.execute(
        "select count(*) from turns "
        "where assistant_timestamp is null or assistant_timestamp = ''").fetchone()[0]
    if inflight:
        print(0); raise SystemExit

    # 取「双方都停下」的时刻。
    #
    # ⚠️ SQLite 陷阱：max(a, b) 传两个参数时是**标量函数**（逐行取较大值），
    #    不是聚合函数。写成 `select max(a, b) from turns` 会返回**任意一行**的值 ——
    #    实测拿到过 21 小时前的时间戳，导致空闲判定永远通过、每轮都冒泡。
    #    必须嵌套一层：内层逐行取较大者，外层聚合取最大。
    row = con.execute(
        "select max(m) from ("
        "  select max(coalesce(user_timestamp,''), coalesce(assistant_timestamp,'')) as m"
        "  from turns)").fetchone()
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
# ------------------------------------------------------------------------------
#  cycle —— 一个完整周期：掷骰子 → 等待 → 检查 → 生成 → 投递
#
#  返回 0 = 真的冒了一次泡
#       1 = 本轮跳过（静音 / 对方还在聊 / 撞车 / 模型没返回）
#
#  抽成函数是为了让 --once（手动触发）和常驻循环走同一份代码 ——
#  之前 ctl 的 now 里另抄了一份通知逻辑，两份代码必然漂移。
# ------------------------------------------------------------------------------
cycle() {
    if [ "$FORCE" = "1" ]; then
        idle=$(idle_seconds)
        log "手动触发（当前空闲 ${idle}s）"
    else
        interval=$(roll)
        log "掷骰子 → ${interval}s（$(( interval / 60 )) 分钟）后检查"
        sleep "$interval"
    fi

    # 静音开关
    if [ -e "$OFF_SWITCH" ]; then
        log "已静音（存在 $OFF_SWITCH），跳过本轮"
        return 1
    fi

    if [ "$FORCE" != "1" ]; then
        idle=$(idle_seconds)
        if [ "$idle" -lt "$interval" ]; then
            log "对方还在聊（空闲 ${idle}s < ${interval}s），重掷不打扰"
            return 1
        fi
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
    if [ -n "$TARGET_SESSION" ]; then
        raw=$(miyu ask --session "$TARGET_SESSION" --output-format json --timeout 180 "$prompt" 2>/dev/null)
        rc=$?
    else
        raw=$(miyu ask -c --output-format json --timeout 180 "$prompt" 2>/dev/null)
        rc=$?
    fi

    if [ "$rc" -ne 0 ]; then
        log "⚠️ miyu 退出码 $rc，本轮放弃"
        return 1
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
        return 1
    fi

    # ── 占位符保护 ──────────────────────────────────────────────────────────
    # 当这一轮撞上别人正在处理的回合时，miyu 不会立刻生成内容，而是先写一段
    # <system-reminder>…正在由另一轮回复处理中…</system-reminder> 占位。
    #
    # 实测（2026-09-23）：这不是失败 —— miyu 会把我们的 prompt 排队，
    # 等对方回合跑完后**用真实回复覆写**这条记录（DB 里能看到 assistant_content
    # 被替换成正常内容）。
    #
    # 但 CLI 在这一刻返回的就是那段占位文本。**绝不能把它弹到桌面通知里** ——
    # 用户看到的是系统内部告警，直接出戏。
    #
    # 所以这里放弃本轮（消息其实已经进会话了，只是没有通知）。
    if printf '%s' "$msg" | grep -qE '<system-reminder>|正在由另一轮回复处理中|已被中断'; then
        log "⚠️ 撞上在飞的回合，miyu 返回占位符（prompt 已排队，稍后会被真实回复覆写），本轮不通知"
        return 1
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

    # ── 投递：带按钮，点了直接接上对话 ───────────────────────────────────────
    #
    #  为什么要有按钮：通知是单向的。用户看到消息却回不了，等于被搭话却张不开嘴。
    #
    #  notify-send 的 --action 隐含 --wait，会一直阻塞到用户点击或关掉 ——
    #  所以整段丢到子 shell 里后台跑，不堵住主循环。
    #
    #  点击「去回她」的动作：开一个新的 kitty 跑 miyu REPL。
    #  为什么开新的而不是聚焦已有的：已有窗口里跑的是什么不确定，
    #  而新开的 REPL 一定会重放最近几轮（repl_replay_turns），
    #  保证那条冒泡就摆在眼前，接着打字就是回复。
    (
        selected=$(notify-send -a "小鱼" -i face-smile \
            -h string:x-canonical-private-synchronous:miyu-bubble \
            --action="reply=去回她" \
            --action="dismiss=知道了" \
            "小鱼找你" "$msg" 2>/dev/null)

        case "${selected:-}" in
            reply)
                log "用户点了「去回她」，打开终端"
                if command -v niri >/dev/null 2>&1; then
                    niri msg action spawn -- kitty --title "小鱼" miyu >/dev/null 2>&1 \
                        || setsid kitty --title "小鱼" miyu >/dev/null 2>&1 &
                else
                    setsid kitty --title "小鱼" miyu >/dev/null 2>&1 &
                fi
                ;;
        esac
    ) &
    disown 2>/dev/null || true

    log "已投递通知（带按钮）"
    return 0
}

# ==============================================================================
#  5. 驱动
# ==============================================================================
if [ "$ONCE" = "1" ]; then
    # --once：立刻跑一轮（跳过掷骰子与空闲判定），给 ctl 的 now 用
    cycle
    exit $?
fi

log "── 启动 ── 基准 ${BASE}s ×[${JITTER_MIN},${JITTER_MAX}]  目标会话=${TARGET_SESSION:-（跟随当前）}"
while true; do
    cycle || true
done
