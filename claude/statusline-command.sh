#!/bin/bash
input=$(cat)

cwd=$(echo "$input" | jq -r '.cwd // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
ctx_used=$(echo "$input" | jq -r '(.context_window.total_input_tokens + .context_window.total_output_tokens) // empty')
ctx_max=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

# Sandbox: merge global + project settings (project overrides global)
global_sandbox=$(jq -r '.sandbox // empty' ~/.claude/settings.json 2>/dev/null)
project_settings="${cwd}/.claude/settings.json"
project_sandbox=$(jq -r '.sandbox // empty' "$project_settings" 2>/dev/null)
sandbox="${project_sandbox:-$global_sandbox}"

parts=()

# 1. Working dir + git branch
if [ -n "$cwd" ]; then
    branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$branch" ]; then
        parts+=("$(printf '\033[01;34m%s\033[00m \033[0;35m(%s)\033[00m' "$cwd" "$branch")")
    else
        parts+=("$(printf '\033[01;34m%s\033[00m' "$cwd")")
    fi
fi

# 3. Model name
if [ -n "$model" ]; then
    parts+=("$(printf '\033[0;36m%s\033[00m' "$model")")
fi

# 4. Sandbox status
if [ -n "$sandbox" ]; then
    parts+=("$(printf '\033[0;32msandbox: on\033[00m')")
else
    parts+=("$(printf '\033[0;31msandbox: off\033[00m')")
fi

# 5. Context window usage
if [ -n "$ctx_used" ] && [ -n "$ctx_max" ] && [ -n "$ctx_pct" ]; then
    used_k=$(echo "$ctx_used" | awk '{printf "%.0fk", $1/1000}')
    max_k=$(echo "$ctx_max" | awk '{printf "%.0fk", $1/1000}')
    parts+=("$(printf '\033[0;37mcontext: %s / %s (%d%%)\033[00m' "$used_k" "$max_k" "$ctx_pct")")
fi

# 6. 5-hour window usage
if [ -n "$five_pct" ]; then
    parts+=("$(printf '\033[0;33m5h:%.0f%%\033[00m' "$five_pct")")
fi

# 7. 7-day window usage
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
