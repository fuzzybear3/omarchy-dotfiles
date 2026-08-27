#!/bin/sh
# Claude Code statusLine command
# Derived from ~/.p10k.zsh (Powerlevel10k Pure style)
#
# Colors matching p10k snazzy palette:
#   grey    = ansi 242
#   blue    = #57C7FF  -> closest 256-color: 81
#   magenta = #FF6AC1  -> closest 256-color: 205
#   cyan    = #9AEDFE  -> closest 256-color: 123
#   yellow  = #F3F99D  -> closest 256-color: 228
#   green   = #5AF78E  -> closest 256-color: 84

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd')
model=$(echo "$input" | jq -r '.model.display_name')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
tok_used=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
tok_limit=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_hour_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')

# cwd basename (blue 81) — show just the leaf directory
printf "\033[38;5;81m%s\033[0m" "$(basename "$cwd")"

# git branch (grey 242) — skip optional locks
if git_dir=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --git-dir 2>/dev/null); then
  branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \
           || GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  dirty=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" status --porcelain 2>/dev/null | head -1)
  dirty_mark=""
  [ -n "$dirty" ] && dirty_mark="*"
  printf "  \033[38;5;242m%s%s\033[0m" "$branch" "$dirty_mark"
fi

# Pick ansi color by percentage threshold:
#   < 60  green 84
#   < 85  yellow 228
#   >=85  red 203
threshold_color() {
  awk -v p="$1" 'BEGIN {
    if (p < 60)      print 84
    else if (p < 85) print 228
    else             print 203
  }'
}

# context used % + token count — combined into one block
if [ -n "$used" ] || [ -n "$tok_used" ]; then
  printf "  "
  if [ -n "$used" ]; then
    ctx_color=$(threshold_color "$used")
    printf "\033[38;5;%dmctx:%s%%\033[0m" "$ctx_color" "$(printf '%.0f' "$used")"
  fi
  if [ -n "$tok_used" ]; then
    fmt_k() { awk -v n="$1" 'BEGIN { printf "%dk", int(n/1000 + 0.5) }'; }
    [ -n "$used" ] && printf " "
    printf "\033[38;5;123m%s/%s\033[0m" "$(fmt_k "$tok_used")" "$(fmt_k "$tok_limit")"
  fi
fi

# 5-hour rolling rate limit — only present for Pro/Max subscribers after first API response
if [ -n "$five_hour_pct" ]; then
  five_color=$(threshold_color "$five_hour_pct")
  printf "  \033[38;5;%dm5h:%s%%\033[0m" "$five_color" "$(printf '%.0f' "$five_hour_pct")"
  if [ -n "$five_hour_reset" ]; then
    printf "\033[38;5;%dm→%s\033[0m" "$five_color" "$(date -d "@$five_hour_reset" +%H:%M)"
  fi
fi

# session cost (green 84) — only when available; resets per session, not per 5h window
if [ -n "$cost" ]; then
  printf "  \033[38;5;84m\$%s\033[0m" "$(printf '%.2f' "$cost")"
fi

# model (grey 242) — last since it's the lowest-priority info
printf "  \033[38;5;242m%s\033[0m" "$model"
