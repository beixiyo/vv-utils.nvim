#!/bin/sh
# 共享隔离入口。依赖策略由 tests/env.sh 负责
set -eu
runner_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo=${1:-.}
if [ "$#" -gt 0 ]; then
  shift
fi

if [ "$#" -gt 1 ]; then
  printf 'usage: %s <plugin-root> [literal-filter]\n' "$0" >&2
  exit 2
fi
repo=$(CDPATH= cd -- "$repo" && pwd -P)
export VV_TEST_REPO="$repo"

. "$runner_dir/paths.sh"
vv_test_clean_environment
vv_test_freeze_paths
vv_test_path VV_UTILS "$runner_dir/../.." dev/test/run.sh dev/test/paths.sh lua/vv-utils/init.lua

if [ -f "$repo/tests/env.sh" ]; then
  . "$repo/tests/env.sh"
fi

temporary_root=$(vv_test_absolute "${TMPDIR:-/tmp}")
scratch=$(mktemp -d "$temporary_root/vv-nvim-tests.XXXXXX")
child_pid=

cleanup() {
  rm -rf "$scratch"
}

# 信号退出仍视为失败；不能只做清理然后继续运行测试套件
interrupted() {
  trap '' HUP INT TERM
  if [ -n "$child_pid" ]; then
    "$NVIM_BIN" --headless -u NONE -i NONE -n -l "$runner_dir/stop.lua" "$child_pid" || :
    # 测试进程可能阻塞在 RPC 或 Neovim 的优雅信号处理器中
    # fixture 没有需要保留的用户缓冲区；明确终止本次拥有的进程
    kill -KILL "$child_pid" 2>/dev/null || :
    wait "$child_pid" 2>/dev/null || :
  fi
  exit "$1"
}

trap cleanup 0
trap 'interrupted 129' HUP
trap 'interrupted 130' INT
trap 'interrupted 143' TERM

mkdir -p "$scratch/home" "$scratch/tmp" "$scratch/runtime"
export HOME="$scratch/home" TMPDIR="$scratch/tmp" XDG_RUNTIME_DIR="$scratch/runtime"
export XDG_STATE_HOME="$scratch/state" XDG_DATA_HOME="$scratch/data"
export XDG_CACHE_HOME="$scratch/cache" XDG_CONFIG_HOME="$scratch/config"

"$NVIM_BIN" --headless -u NONE -i NONE -n -l "$runner_dir/run.lua" "$repo" "${1:-}" &
child_pid=$!
status=0
wait "$child_pid" || status=$?
child_pid=
exit "$status"
