#!/bin/sh
# Claude Code status line — derived from ~/.bashrc PS1
input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd')
model=$(echo "$input" | jq -r '.model.display_name // empty')

# Detect git branch at the session's cwd (skip all optional locks)
branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)

# Build the status line
printf "\033[01;32m%s@%s\033[00m:\033[01;34m%s\033[00m" "$(whoami)" "$(hostname -s)" "$cwd"

if [ -n "$branch" ]; then
    printf " \033[01;36m(%s)\033[00m" "$branch"
fi

if [ -n "$model" ]; then
    printf " \033[00;33m[%s]\033[00m" "$model"
fi
