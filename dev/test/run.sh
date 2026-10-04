#!/bin/sh
# 显式开发入口：隔离 Neovim 持久目录，并复用全局测试依赖缓存
set -eu
runner_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=${1:-.}
if [ "$#" -gt 0 ]; then shift; fi
if [ "$#" -gt 1 ]; then
  printf 'usage: %s <plugin-root> [literal-filter]\n' "$0" >&2
  exit 2
fi
repo=$(CDPATH= cd -- "$repo" && pwd)
export VV_TEST_REPO="$repo"

# 返回调用者声明的源码目录；覆盖值相对原 cwd 解析，不在 child 换 cwd 后再猜路径
# 用法：VAR=$(vv_test_source_path VAR /default/source)，由各仓 tests/env.sh 决定依赖策略
vv_test_source_path() (
  case "$1" in
    ''|[0-9]*|*[!A-Z0-9_]*) printf '非法测试环境变量名：%s\n' "$1" >&2; exit 2 ;;
  esac
  eval "vv_source=\${$1-}"
  vv_source=${vv_source:-$2}
  if [ ! -d "$vv_source" ]; then
    printf '找不到已安装的测试依赖：%s=%s；请准备该源码/runtime，或通过 %s 指定位置\n' "$1" "$vv_source" "$1" >&2
    exit 1
  fi
  CDPATH= cd -- "$vv_source" && pwd
)

# 在 HOME/XDG 隔离前保存已有 runtime 与缓存位置；只接入数据，不加载个人 init.lua
export VV_TEST_SITE="${VV_TEST_SITE:-${XDG_DATA_HOME:-$HOME/.local/share}/${NVIM_APPNAME:-nvim}/site}"
if [ -d "$VV_TEST_SITE" ]; then
  VV_TEST_SITE=$(vv_test_source_path VV_TEST_SITE "$VV_TEST_SITE")
fi
export VV_TEST_DEPS_CACHE="${VV_TEST_DEPS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/nvim-test-deps}"
# 共享层仅加载声明，不硬编码任何 vv 插件或语言工具链
if [ -f "$repo/tests/env.sh" ]; then . "$repo/tests/env.sh"; fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/vv-nvim-tests.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/home" "$scratch/tmp" "$scratch/runtime"
export HOME="$scratch/home"
export TMPDIR="$scratch/tmp"
export XDG_RUNTIME_DIR="$scratch/runtime"
export XDG_STATE_HOME="$scratch/state"
export XDG_DATA_HOME="$scratch/data"
export XDG_CACHE_HOME="$scratch/cache"
export XDG_CONFIG_HOME="$scratch/config"
"${NVIM_BIN:-nvim}" --headless -u NONE -i NONE -n -l "$runner_dir/run.lua" "$repo" "${1:-}"
