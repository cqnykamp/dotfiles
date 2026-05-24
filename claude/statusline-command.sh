#!/bin/bash
input=$(cat)

cwd=$(echo "$input" | jq -r '.cwd // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

parts=()

# 1. Working dir (basename only)
if [ -n "$cwd" ]; then
    parts+=("$(printf '\033[02m~/\033[00m\033[01;34m%s\033[00m' "$(basename "$cwd")")")
fi

# 2. Git branch
if [ -n "$cwd" ]; then
    branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$branch" ]; then
        parts+=("$(printf '\033[0;35mbranch:%s\033[00m' "$branch")")
    fi
fi

# 3. Model name
if [ -n "$model" ]; then
    parts+=("$(printf '\033[0;36m%s\033[00m' "$model")")
fi

# 4. 5-hour window usage
if [ -n "$five_pct" ]; then
    parts+=("$(printf '\033[0;33m5h:%.0f%%\033[00m' "$five_pct")")
fi

# 5. 7-day window usage
if [ -n "$week_pct" ]; then
    parts+=("$(printf '\033[0;33m7d:%.0f%%\033[00m' "$week_pct")")
fi

output=""
for part in "${parts[@]}"; do
    if [ -z "$output" ]; then
        output="$part"
    else
        output="$output $(printf '\033[02m|\033[00m') $part"
    fi
done

printf '%s' "$output"
