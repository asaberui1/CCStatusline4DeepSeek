#!/bin/bash
# Claude Code status line — two-line layout, block progress bar
# Reads JSON from stdin, accumulates cost per session in ~/.claude/cache/

input=$(cat)
echo "$input" >/tmp/rtk_statusline_latest.json

# === ANSI Colors ===
RST='\033[0m'
DIM='\033[90m'
BOLD='\033[1m'
CYAN='\033[36m'
YELLOW='\033[33m'
GREEN='\033[32m'
BLUE='\033[34m'
MAG='\033[35m'
RED='\033[31m'
GOLD='\033[38;5;220m'

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
  echo "scale=8; ($i * $MISS_RATE + $cr * $HIT_RATE + $cc * $MISS_RATE + $o * $OUT_RATE) / 1000000" |
    bc -l 2>/dev/null | sed 's/^\./0./'
}

# === Cost-based Accumulator (per-round deltas, model-aware) ===
ACCUM_FILE="$HOME/.claude/cache/statusline_cost.json"
mkdir -p "$HOME/.claude/cache"

if [ -f "$ACCUM_FILE" ]; then
  accum=$(cat "$ACCUM_FILE")
else
  accum='{}'
fi

session_accum=$(echo "$accum" | jq -r --arg sid "$session_id" '.[$sid] // empty' 2>/dev/null)
if [ -z "$session_accum" ] || [ "$session_accum" = "null" ]; then
  session_accum='{"total_cost":0,"last_turn_cost":0,"last_in":0,"last_out":0,"last_cache_read":0,"last_cache_create":0}'
fi

re='^[0-9]+$'
has_new_data=false
if [[ $out_tok =~ $re ]] && [ "$out_tok" -gt 0 ]; then
  prev_out=$(echo "$session_accum" | jq -r '.last_out // -1')
  if [ "$out_tok" != "$prev_out" ] 2>/dev/null; then
    has_new_data=true
  fi
fi

if $has_new_data; then
  prev_in=$(echo "$session_accum" | jq -r '[.last_in // 0, 0] | max')
  prev_out=$(echo "$session_accum" | jq -r '[.last_out // 0, 0] | max')
  prev_cr=$(echo "$session_accum" | jq -r '[.last_cache_read // 0, 0] | max')
  prev_cc=$(echo "$session_accum" | jq -r '[.last_cache_create // 0, 0] | max')

  # Delta tokens for this round (snapshot comparison)
  delta_in=$((in_tok - prev_in))
  delta_out=$((out_tok - prev_out))
  delta_cr=$((cache_read - prev_cr))
  delta_cc=$((cache_create - prev_cc))

  # Clamp deltas to non-negative (safety for edge cases)
  [ "$delta_in" -lt 0 ] && delta_in=0
  [ "$delta_out" -lt 0 ] && delta_out=0
  [ "$delta_cr" -lt 0 ] && delta_cr=0
  [ "$delta_cc" -lt 0 ] && delta_cc=0

  # Delta cost priced at current model's rates
  turn_cost=$(calc_cost "$delta_in" "$delta_cr" "$delta_cc" "$delta_out")

  # Accumulate total cost
  total_cost=$(echo "$session_accum" | jq -r '.total_cost // 0')
  total_cost=$(echo "scale=8; $total_cost + $turn_cost" | bc -l 2>/dev/null | sed 's/^\./0./')
  [ -z "$total_cost" ] && total_cost=0

  new_entry=$(jq -n \
    --argjson tc "$total_cost" \
    --argjson ltc "$turn_cost" \
    --argjson li "$in_tok" --argjson lo "$out_tok" \
    --argjson lcr "$cache_read" --argjson lcc "$cache_create" \
    '{
            total_cost: $tc,
            last_turn_cost: $ltc,
            last_in: $li, last_out: $lo,
            last_cache_read: $lcr, last_cache_create: $lcc
        }')
  echo "$accum" | jq --arg sid "$session_id" --argjson ne "$new_entry" \
    '.[$sid] = $ne' >"$ACCUM_FILE"
else
  total_cost=$(echo "$session_accum" | jq -r '.total_cost // 0')
  turn_cost=$(echo "$session_accum" | jq -r '.last_turn_cost // 0')
fi

safe_val() {
  local v=$1
  [ -z "$v" ] || [ "$v" = "null" ] && echo 0 || echo "$v"
}
in_tok=$(safe_val "$in_tok")
out_tok=$(safe_val "$out_tok")
cache_read=$(safe_val "$cache_read")
cache_create=$(safe_val "$cache_create")

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
  if [ -z "$n" ] || [ "$n" = "0" ]; then
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
  local r
  if [ "$(echo "$c >= 1" | bc -l 2>/dev/null)" = "1" ]; then
    r=$(printf "%.2f" "$c")
  else
    r=$(printf "%.4f" "$c")
    r=$(echo "$r" | sed 's/0\{1,2\}$//')
    [[ "$r" == *"." ]] && r="${r}00"
  fi
  echo "¥$r"
}

# Get git branch
branch=""
if [ -n "$cwd" ] && [ -d "$cwd/.git" ]; then
  branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || true)
fi

# === Progress Bar: 24 blocks ===
# ██ = remaining (colored), ░░ = used (gray)
# Format: ████████████████████░░░░ 82.9%
make_progress_bar() {
  local pct=$1
  if [ -z "$pct" ]; then
    echo ""
    return
  fi

  # 16 blocks total (fits well on one line)
  local total=16
  # pct is remaining percentage, calculate filled blocks
  # Use awk for float math
  local filled
  filled=$(awk -v p="$pct" -v t="$total" 'BEGIN { printf "%d", (p * t / 100) + 0.5 }' 2>/dev/null)
  [ -z "$filled" ] && filled=0
  [ "$filled" -gt "$total" ] && filled=$total
  [ "$filled" -lt 0 ] && filled=0
  local empty=$((total - filled))

  # Color based on remaining percentage
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
  # Remaining portion (right side) — colored blocks █
  for ((i = 0; i < filled; i++)); do
    bar="${bar}${bar_color}█${RST}"
  done
  # Used portion (left side) — gray shade ░
  for ((i = 0; i < empty; i++)); do
    bar="${bar}${DIM}░${RST}"
  done

  # Percentage after bar, 1 decimal
  local pct_str
  pct_str=$(printf "%.1f%%" "$pct")
  echo "$bar ${pct_str}"
}

# === Build display ===

# Token numbers fixed-width (right-aligned to 6)
in_fmt=$(format_num "$in_tok")
in_pad=$(pad_r "${in_fmt:-}" 6)
out_fmt=$(format_num "$out_tok")
out_pad=$(pad_r "${out_fmt:-}" 6)
cr_fmt=$(format_num "$cache_read")
cr_pad=$(pad_r "${cr_fmt:-}" 6)

# Cost fixed-width
turn_c=$(fmt_cost_fixed "$turn_cost")
turn_pad=$(pad_l "${turn_c:-}" 8)
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

# Dir
[ -n "$short_dir" ] && line1="$line1  ${YELLOW}${short_dir}${RST}"

# Branch
[ -n "$branch" ] && line1="$line1  ${GREEN}${branch}${RST}"

# Session name
[ -n "$session" ] && line1="$line1 ${DIM}[${session}]${RST}"

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
# LINE 2: Token usage + cost
# ====================
has_token_data=false
line2=""

if [ -n "$in_fmt" ] || [ -n "$out_fmt" ] || [ -n "$cr_fmt" ]; then
  has_token_data=true
  line2="${line2}输入${BLUE}${in_pad}${RST}  输出${MAG}${out_pad}${RST}  缓存${GREEN}${cr_pad}${RST}"
fi

if $has_token_data; then
  cost_line="  ${DIM}|${RST}"
  # 本轮: fallback to ¥0 on zero-cost refresh
  display_turn="${turn_c:-¥0}"
  turn_pad=$(pad_l "${display_turn}" 8)
  cost_line="${cost_line} 本轮${GOLD}${turn_pad}${RST}"
  # 累计
  if [ -n "$cumul_c" ]; then
    cost_line="${cost_line}  累计${GOLD}${cumul_pad}${RST}"
  fi
  # 余额
  if [ -n "$balance" ]; then
    bal_fmt=$(printf "¥%.2f" "$balance" 2>/dev/null)
    bal_pad=$(pad_l "${bal_fmt}" 10)
    cost_line="${cost_line}  余额${GOLD}${bal_pad}${RST}"
  fi
  line2="$line2${cost_line}"
fi

# === Final output ===
if $has_token_data; then
  echo -e "$line1\n$line2"
else
  echo -e "$line1"
fi
