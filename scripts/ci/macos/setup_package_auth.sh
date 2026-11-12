#!/bin/bash
set -euo pipefail
umask 077

: "${GH_TOKEN:?需要 GitHub Actions token}"
: "${RUNNER_TEMP:?需要 GitHub Actions 临时目录}"
: "${GITHUB_PATH:?需要 GitHub Actions PATH 文件}"

# 使用环境变量写入凭据，避免 token 出现在命令参数或日志中。
printf 'machine github.com\nlogin x-access-token\npassword %s\nmachine api.github.com\nlogin x-access-token\npassword %s\n' \
  "$GH_TOKEN" "$GH_TOKEN" > "$HOME/.netrc"
chmod 600 "$HOME/.netrc"

wrapper_dir="$RUNNER_TEMP/fluxdo-xcode-tools"
mkdir -p "$wrapper_dir"
cp "$(dirname "$0")/xcrun" "$wrapper_dir/xcrun"
chmod 700 "$wrapper_dir/xcrun"
printf '%s\n' "$wrapper_dir" >> "$GITHUB_PATH"
