#!/bin/sh
# Unix-like 自测入口：只要求 Bun、Neovim 和 Git，不依赖个人配置或预热缓存
set -eu
selftest_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$selftest_dir/../paths.sh"

vv_test_clean_environment
if ! command -v bun >/dev/null 2>&1; then
  printf 'Framework self-tests require Bun; install it before running this entrypoint.\n' >&2
  exit 1
fi

exec bun run "$selftest_dir/run.ts"
