#!/bin/bash
# Status line derived from PS1='[\u@\h \W]\$ ' in ~/.bashrc
input=$(cat)
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
model=$(echo "$input" | jq -r '.model.display_name // empty')
w=$(basename "$cwd")

branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)

out=$(printf "[%s@%s %s]" "$(whoami)" "$(hostname -s)" "$w")
[ -n "$branch" ] && out="$out ($branch)"
[ -n "$model" ] && out="$out [$model]"
printf "%s" "$out"
