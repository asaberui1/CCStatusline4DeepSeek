#!/bin/bash
# Claude Code status line — two-line layout, block progress bar
# Reads JSON from stdin, accumulates cost per session in ~/.claude/cache/

input=$(cat)
echo "$input" >/tmp/rtk_statusline_latest.json

# === ANSI Colors ===
RST=$'\033[0m'
DIM=$'\033[90m'
BOLD=$'\033[1m'
CYAN=$'\033[36m'
YELLOW=$'\033[33m'
GREEN=$'\033[32m'
BLUE=$'\033[34m'
MAG=$'\033[35m'
RED=$'\033[31m'
GOLD=$'\033[38;5;220m'

# === Extract JSON fields ===
model=$(echo "$input" | jq -r '.model.display_name // empty')
model_id=$(echo "$input" | jq -r '.model.id // empty')
session=$(echo "$input" | jq -r '.session_name // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // empty')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
effort=$(echo "$input" | jq -r '.effort.level // empty')

in_tok=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // empty')
out_tok=$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // empty')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // empty')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // empty')

total_in_tok=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
total_out_tok=$(echo "$input" | jq -r '.context_window.total_output_tokens // empty')

# === Model Pricing ===
case "$model_id" in
*flash*)
  HIT_RATE=0.02
  MISS_RATE=1
  OUT_RATE=2
  ;;
*pro*)
  HIT_RATE=0.025
  MISS_RATE=3
  OUT_RATE=6
  ;;
*)
  HIT_RATE=0.02
  MISS_RATE=1
  OUT_RATE=2
  ;;
esac

calc_cost() {
  local i=$1 cr=$2 cc=$3 o=$4
  # 余额来自 DeepSeek API，精确可靠。累计成本基于 token 用量 × 模型定价估算，
  # 由于无法获取 API 返回的精确账单（尤其是缓存命中/未命中拆分），
  # 实际成本以 DeepSeek 对账单为准。
  echo "scale=8; ($i * $MISS_RATE + $cr * $HIT_RATE + $cc * $MISS_RATE + $o * $OUT_RATE) / 1000000" |
    bc -l 2>/dev/null | sed 's/^\./0./'
}

# === Cost-based Accumulator (cumulative deltas, model-aware) ===
ACCUM_FILE="$HOME/.claude/cache/statusline_cost.json"
mkdir -p "$HOME/.claude/cache"

if [ -f "$ACCUM_FILE" ]; then
  accum=$(cat "$ACCUM_FILE")
  [ -z "$accum" ] && accum='{}'
else
  accum='{}'
fi

session_accum=$(echo "$accum" | jq -r --arg sid "$session_id" '.[$sid] // empty' 2>/dev/null)
if [ -z "$session_accum" ] || [ "$session_accum" = "null" ]; then
  session_accum='{"total_cost":0,"prev_in":0,"prev_out":0,"prev_cache_read":0,"prev_cache_create":0,"prev_total_in":0,"prev_total_out":0}'
fi

re='^[0-9]+$'
has_new_data=false
if [[ $total_out_tok =~ $re ]] && [ "$total_out_tok" -gt 0 ]; then
  prev_total_out=$(echo "$session_accum" | jq -r '.prev_total_out // 0')
  [ "$total_out_tok" -gt "$prev_total_out" ] 2>/dev/null && has_new_data=true
fi
if ! $has_new_data && [[ $total_in_tok =~ $re ]] && [ "$total_in_tok" -gt 0 ]; then
  prev_total_in=$(echo "$session_accum" | jq -r '.prev_total_in // 0')
  [ "$total_in_tok" -gt "$prev_total_in" ] 2>/dev/null && has_new_data=true
fi

# Read stored values (needed in both branches)
prev_total_in=$(echo "$session_accum" | jq -r '[.prev_total_in // 0, 0] | max')
prev_total_out=$(echo "$session_accum" | jq -r '[.prev_total_out // 0, 0] | max')
prev_cr=$(echo "$session_accum" | jq -r '[.prev_cache_read // 0, 0] | max')
prev_cc=$(echo "$session_accum" | jq -r '[.prev_cache_create // 0, 0] | max')
prev_in=$(echo "$session_accum" | jq -r '[.prev_in // 0, 0] | max')
prev_remaining=$(echo "$session_accum" | jq -r '.prev_remaining // empty')

# === Rewind Detection ===
# Rewind: curr_in drops (by >10K), total_in unchanged (no API call), remaining doesn't spike
# (Large remaining spike = client-side compact; total_in increase = API-side compact — both ignored)
rewind_happened=false
drop=$((prev_in - in_tok))
delta_total_in=$((total_in_tok - prev_total_in))

remaining_delta=""
if [ -n "$prev_remaining" ] && [ -n "$remaining" ] && [ "$remaining" != "null" ]; then
  remaining_delta=$(echo "$remaining - $prev_remaining" | bc -l 2>/dev/null)
fi

if [ "$drop" -gt 10000 ] 2>/dev/null; then
  if [ "$delta_total_in" -le 0 ] 2>/dev/null && [ "$(echo "$remaining_delta <= 20" | bc -l 2>/dev/null)" = "1" ]; then
    rewind_happened=true
  fi
fi

if $has_new_data; then
  # Delta using CUMULATIVE values (accurate for billing)
  delta_in=$((total_in_tok - prev_total_in))
  delta_out=$((total_out_tok - prev_total_out))
  # Cache: only non-negative delta from snapshots (best approximation)
  [ "$cache_read" -gt "$prev_cr" ] 2>/dev/null && delta_cr=$((cache_read - prev_cr)) || delta_cr=0
  [ "$cache_create" -gt "$prev_cc" ] 2>/dev/null && delta_cc=$((cache_create - prev_cc)) || delta_cc=0

  # Delta cost
  turn_cost=$(calc_cost "$delta_in" "$delta_cr" "$delta_cc" "$delta_out")

  # Accumulate total cost
  total_cost=$(echo "$session_accum" | jq -r '.total_cost // 0')
  total_cost=$(echo "scale=8; $total_cost + $turn_cost" | bc -l 2>/dev/null | sed 's/^\./0./')
  [ -z "$total_cost" ] && total_cost=0

  new_entry=$(jq -n \
    --argjson tc "$total_cost" \
    --argjson pi "$in_tok" --argjson po "$out_tok" \
    --argjson pcr "$cache_read" --argjson pcc "$cache_create" \
    --argjson pti "$total_in_tok" --argjson pto "$total_out_tok" \
    --arg pr "$remaining" \
    '{
      total_cost: $tc,
      prev_in: $pi, prev_out: $po,
      prev_cache_read: $pcr, prev_cache_create: $pcc,
      prev_total_in: $pti, prev_total_out: $pto,
      prev_remaining: ($pr | tonumber? // 0)
    }')
  echo "$accum" | jq --arg sid "$session_id" --argjson ne "$new_entry" \
    '.[$sid] = $ne' >"$ACCUM_FILE"
else
  total_cost=$(echo "$session_accum" | jq -r '.total_cost // 0')
  # On rewind: update snapshots so next prompt doesn't false-positive as rewind
  if $rewind_happened; then
    new_entry=$(jq -n \
      --argjson tc "$total_cost" \
      --argjson pi "$in_tok" --argjson po "$out_tok" \
      --argjson pcr "$cache_read" --argjson pcc "$cache_create" \
      --argjson pti "$total_in_tok" --argjson pto "$total_out_tok" \
      --arg pr "$remaining" \
      '{
        total_cost: $tc, prev_in: $pi, prev_out: $po,
        prev_cache_read: $pcr, prev_cache_create: $pcc,
        prev_total_in: $pti, prev_total_out: $pto,
        prev_remaining: ($pr | tonumber? // 0)
      }')
    echo "$accum" | jq --arg sid "$session_id" --argjson ne "$new_entry" \
      '.[$sid] = $ne' >"$ACCUM_FILE"
  fi
fi

safe_val() {
  local v=$1
  [ -z "$v" ] || [ "$v" = "null" ] && echo 0 || echo "$v"
}
in_tok=$(safe_val "$in_tok")
out_tok=$(safe_val "$out_tok")
cache_read=$(safe_val "$cache_read")
cache_create=$(safe_val "$cache_create")
total_in_tok=$(safe_val "$total_in_tok")
total_out_tok=$(safe_val "$total_out_tok")

cumul_cost=$total_cost

# === Balance Fetching (cached 60s) ===
balance=""
if [ -n "$ANTHROPIC_AUTH_TOKEN" ]; then
  BALANCE_CACHE="$HOME/.claude/cache/statusline_balance.cache"
  # Simple time-based cache check — write mtime into cache file itself (first line)
  if [ -f "$BALANCE_CACHE" ]; then
    cached=$(head -1 "$BALANCE_CACHE")
    cache_time=$(echo "$cached" | cut -d'|' -f1)
    now=$(date +%s)
    if [ "$((now - cache_time))" -lt 60 ] 2>/dev/null; then
      balance=$(echo "$cached" | cut -d'|' -f2-)
    fi
  fi
  if [ -z "$balance" ]; then
    resp=$(curl -s --max-time 5 \
      -H 'Accept: application/json' \
      -H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
      'https://api.deepseek.com/user/balance' 2>/dev/null)
    balance=$(echo "$resp" | jq -r '.balance_infos[0].total_balance // empty')
    if [ -n "$balance" ]; then
      echo "$(date +%s)|$balance" >"$BALANCE_CACHE"
    fi
  fi
fi

# === Formatters ===

pad_r() {
  local str=$1 w=$2
  printf "%*s" "$w" "$str"
}
pad_l() {
  local str=$1 w=$2
  printf "%-*s" "$w" "$str"
}

format_num() {
  local n=$1
  if [ -z "$n" ]; then
    echo ""
    return
  fi
  if [ "$n" -ge 1000000 ]; then
    printf "%.1fM" "$(echo "scale=1; $n / 1000000" | bc -l 2>/dev/null)"
  elif [ "$n" -ge 1000 ]; then
    printf "%.1fK" "$(echo "scale=1; $n / 1000" | bc -l 2>/dev/null)"
  else
    echo "$n"
  fi
}

shorten_path() {
  local p=$1
  [ -z "$p" ] && echo "" && return
  echo "$p" | sed "s|$HOME|~|"
}

fmt_cost_fixed() {
  local c=$1
  if [ "$(echo "$c < 0.00000001" | bc -l 2>/dev/null)" = "1" ]; then
    echo ""
    return
  fi
  if [ "$(echo "$c >= 1" | bc -l 2>/dev/null)" = "1" ]; then
    printf "¥%.2f" "$c"
  else
    printf "¥%.4f" "$c"
  fi
}

# Get git branch
branch=""
if [ -n "$cwd" ]; then
  branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || true)
fi

# Git root path highlighting — bold the repo root dir name in cwd
git_root_dir=""
if [ -n "$cwd" ] && [ -n "$branch" ]; then
  git_root=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$git_root" ]; then
    git_root_dir=$(basename "$git_root")
  fi
fi

# === Progress Bar: 16 blocks ===
# █ = remaining (colored), ░ = used (gray)
make_progress_bar() {
  local pct=$1
  local marker=$2  # optional marker shown after percentage
  if [ -z "$pct" ]; then
    echo ""
    return
  fi

  local total=16
  local filled
  filled=$(awk -v p="$pct" -v t="$total" 'BEGIN { printf "%d", (p * t / 100) + 0.5 }' 2>/dev/null)
  [ -z "$filled" ] && filled=0
  [ "$filled" -gt "$total" ] && filled=$total
  [ "$filled" -lt 0 ] && filled=0
  local empty=$((total - filled))

  local bar_color=$GREEN
  if [ "$(echo "$pct >= 50" | bc -l 2>/dev/null)" = "1" ]; then
    bar_color=$GREEN
  elif [ "$(echo "$pct >= 25" | bc -l 2>/dev/null)" = "1" ]; then
    bar_color=$YELLOW
  else
    bar_color=$RED
  fi

  local bar=""
  local i
  for ((i = 0; i < filled; i++)); do
    bar="${bar}${bar_color}█${RST}"
  done
  for ((i = 0; i < empty; i++)); do
    bar="${bar}${DIM}░${RST}"
  done

  local pct_str
  pct_str=$(printf "%.1f%%" "$pct")
  echo "${bar} ${pct_str}${marker}"
}

# === Build display ===

# Cumulative token totals (from total_* — matches API)
total_in_fmt=$(format_num "$total_in_tok")
total_in_pad=$(pad_r "${total_in_fmt:-}" 6)
total_out_fmt=$(format_num "$total_out_tok")
total_out_pad=$(pad_r "${total_out_fmt:-}" 6)

# Cache — show "0" instead of blank when cache is zero
cr_fmt=$(format_num "$cache_read")
if [ -z "$cr_fmt" ] && { [ "$cache_read" -eq 0 ] 2>/dev/null; }; then
  cr_fmt="0"
fi
cr_pad=$(pad_r "${cr_fmt:-}" 6)

# Cost
cumul_c=$(fmt_cost_fixed "$cumul_cost")
cumul_pad=$(pad_l "${cumul_c:-}" 8)

short_dir=$(shorten_path "$cwd")

bar=$(make_progress_bar "$remaining")

# ====================
# LINE 1: Model + dir + branch + progress bar + effort
# ====================
line1=""

# Model
[ -n "$model" ] && line1="${BOLD}${CYAN}${model}${RST}"

# Dir with git root highlighted
if [ -n "$short_dir" ]; then
  if [ -n "$git_root_dir" ]; then
    # Bold the git root directory name in the path
    bold_dir=$(echo "$short_dir" | sed \
      -e "s|/$git_root_dir/|/${BOLD}${git_root_dir}${RST}${YELLOW}/|g" \
      -e "s|/$git_root_dir\$|/${BOLD}${git_root_dir}${RST}|g" \
      -e "s|^$git_root_dir/|${BOLD}${git_root_dir}${RST}${YELLOW}/|g")
    line1="$line1  ${YELLOW}${bold_dir}${RST}"
  else
    line1="$line1  ${YELLOW}${short_dir}${RST}"
  fi
fi

# Branch
[ -n "$branch" ] && line1="$line1  ${GREEN}${branch}${RST}"


# Right side: progress bar + effort
if [ -n "$bar" ]; then
  line1="$line1  $bar"
fi

# Effort level
if [ -n "$effort" ]; then
  case "$effort" in
  low) effort_color=$GREEN ;;
  medium) effort_color=$YELLOW ;;
  high) effort_color=$RED ;;
  *) effort_color=$DIM ;;
  esac
  line1="$line1  ${effort_color}● ${effort}${RST}"
fi

# ====================
# LINE 2: Token usage + cost + balance
# ====================
has_tokens=false
line2=""

# Use numeric values (not formatted) to distinguish "no data" from "zero"
if [ "$total_in_tok" -gt 0 ] 2>/dev/null || [ "$total_out_tok" -gt 0 ] 2>/dev/null || [ "$cache_read" -gt 0 ] 2>/dev/null; then
  has_tokens=true
  line2="累计输入 ${BLUE}${total_in_pad}${RST}  累计输出 ${MAG}${total_out_pad}${RST}  当前缓存 ${GREEN}${cr_pad}${RST}"
fi

if $has_tokens; then
  cost_line="  ${DIM}|${RST}"
  if [ -n "$cumul_c" ]; then
    cost_line="${cost_line}  累计 ${GOLD}${cumul_pad}${RST}"
  fi
  if [ -n "$balance" ]; then
    bal_fmt=$(printf "¥%.2f" "$balance" 2>/dev/null)
    bal_pad=$(pad_l "${bal_fmt}" 10)
    cost_line="${cost_line}  余额 ${GOLD}${bal_pad}${RST}"
  fi
  line2="${line2}${cost_line}"
fi

# === Final output ===
has_balance=false
[ -n "$balance" ] && has_balance=true

if $rewind_happened; then
  # Rewind to start — single line (initialization style)
  if $has_balance; then
    bal_fmt=$(printf "¥%.2f" "$balance" 2>/dev/null)
    echo -e "$line1  ${GOLD}余额 ${bal_fmt}${RST}"
  else
    echo -e "$line1"
  fi
elif $has_tokens; then
  echo -e "$line1\n$line2"
elif $has_balance; then
  bal_fmt=$(printf "¥%.2f" "$balance" 2>/dev/null)
  echo -e "$line1  ${GOLD}余额 ${bal_fmt}${RST}"
else
  echo -e "$line1"
fi
