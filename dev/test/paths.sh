# 共享的仅测试依赖解析逻辑。更改 HOME/XDG/工作目录前加载

vv_test_error() {
  printf 'vv-test: %s\n' "$*" >&2
  return 1
}

vv_test_name() {
  case "$1" in
    ''|[0-9]*|*[!A-Z0-9_]*)
      vv_test_error "invalid environment name: $1"
      return 1
      ;;
  esac
}

vv_test_absolute() {
  case "$1" in
    /*)
      printf '%s\n' "$1"
      ;;
    *)
      printf '%s/%s\n' "$VV_TEST_CALLER_CWD" "$1"
      ;;
  esac
}

vv_test_checked() (
  vv_name=$1
  vv_dir=$2
  shift 2
  vv_dir=$(vv_test_absolute "$vv_dir")
  [ -d "$vv_dir" ] || {
    vv_test_error "$vv_name=$vv_dir: directory missing; install/check out the dependency or set $vv_name"
    exit 1
  }
  for vv_marker do
    [ -e "$vv_dir/$vv_marker" ] || {
      vv_test_error "$vv_name=$vv_dir: missing required marker $vv_marker"
      exit 1
    }
  done
  CDPATH= cd -- "$vv_dir" && pwd -P
)

# 兼容现有 env.sh：输出路径，由调用方负责导出
vv_test_source_path() (
  vv_test_name "$1" || exit
  eval "vv_value=\${$1-}"
  vv_name=$1
  vv_default=$2
  shift 2
  vv_test_checked "$vv_name" "${vv_value:-$vv_default}" "$@"
)

# 校验目录（parser/runtime/toolchain）；导出 VAR，不向标准输出写内容
vv_test_path() {
  vv_test_name "$1" || return
  vv_export=$1
  vv_path=$(vv_test_source_path "$@") || return
  eval "$vv_export=\$vv_path"
  export "$vv_export"
  printf 'vv-test: %s=%s\n' "$vv_export" "$vv_path" >&2
}

# 已有插件源码的查找顺序：显式 VAR > 开发根目录 > lazy > 原生 pack
vv_test_dependency() {
  vv_test_name "$1" || return
  vv_export=$1
  vv_plugin=$2
  shift 2
  case "$vv_plugin" in
    ''|*/*|.*)
      vv_test_error "invalid plugin directory name: $vv_plugin"
      return 1
      ;;
  esac
  eval "vv_value=\${$vv_export-}"
  if [ -n "$vv_value" ]; then
    vv_path=$(vv_test_checked "$vv_export" "$vv_value" "$@") || return
    vv_origin=override
  else
    vv_path=
    vv_origin=discovery
    # 仅搜索已知根目录，不递归扫描 HOME。pack 根目录是 packpath 条目
    for vv_candidate in \
      "${VV_TEST_VENDOR_ROOT:-$VV_TEST_REPO/..}/$vv_plugin" \
      "$VV_TEST_REPO/../$vv_plugin" \
      "$VV_TEST_CONFIG_ROOT/vendors/$vv_plugin" \
      "$VV_TEST_LAZY_ROOT/$vv_plugin" \
      "$VV_TEST_PACK_ROOT"/pack/*/start/"$vv_plugin" \
      "$VV_TEST_PACK_ROOT"/pack/*/opt/"$vv_plugin" \
      "$VV_TEST_CONFIG_ROOT"/pack/*/start/"$vv_plugin" \
      "$VV_TEST_CONFIG_ROOT"/pack/*/opt/"$vv_plugin"; do
      [ -d "$vv_candidate" ] || continue
      # 已存在但不完整的开发检出目录不得回退到缓存副本
      vv_path=$(vv_test_checked "$vv_export" "$vv_candidate" "$@") || return
      break
    done
    [ -n "$vv_path" ] || {
      vv_test_error "$vv_export: cannot find $vv_plugin; install/check out it or set $vv_export=/absolute/checkout"
      return 1
    }
  fi
  eval "$vv_export=\$vv_path"
  export "$vv_export"
  printf 'vv-test: %s=%s (%s)\n' "$vv_export" "$vv_path" "$vv_origin" >&2
}

# 仅添加一个 runtime 根目录，不添加整个 package 树。使用换行分隔以支持空格
vv_test_runtime() {
  vv_test_name "$1" || return
  eval "vv_runtime=\${$1-}"
  [ -n "$vv_runtime" ] || {
    vv_test_error "$1: empty runtime path"
    return 1
  }
  vv_runtime=$(vv_test_checked "$1" "$vv_runtime") || return
  VV_TEST_RUNTIME_PATHS="${VV_TEST_RUNTIME_PATHS:+$VV_TEST_RUNTIME_PATHS
}$vv_runtime"
  export VV_TEST_RUNTIME_PATHS
}

vv_test_freeze_paths() {
  VV_TEST_CALLER_CWD=$(pwd -P)
  VV_TEST_CONFIG_ROOT=$(vv_test_absolute "${XDG_CONFIG_HOME:-$HOME/.config}/${NVIM_APPNAME:-nvim}")
  VV_TEST_DATA_ROOT=$(vv_test_absolute "${XDG_DATA_HOME:-$HOME/.local/share}/${NVIM_APPNAME:-nvim}")
  for vv_root in VV_TEST_VENDOR_ROOT VV_TEST_LAZY_ROOT VV_TEST_PACK_ROOT; do
    eval "vv_value=\${$vv_root-}"
    if [ -n "$vv_value" ]; then
      vv_path=$(vv_test_checked "$vv_root" "$vv_value") || return
      eval "$vv_root=\$vv_path"
    fi
  done
  VV_TEST_LAZY_ROOT=${VV_TEST_LAZY_ROOT:-$VV_TEST_DATA_ROOT/lazy}
  VV_TEST_PACK_ROOT=${VV_TEST_PACK_ROOT:-$VV_TEST_DATA_ROOT/site}

  if [ -n "${VV_TEST_SITE:-}" ]; then
    VV_TEST_SITE=$(vv_test_checked VV_TEST_SITE "$VV_TEST_SITE") || return
  else
    VV_TEST_SITE=$VV_TEST_DATA_ROOT/site
  fi
  VV_TEST_DEPS_CACHE=$(vv_test_absolute "${VV_TEST_DEPS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/nvim-test-deps}")
  export VV_TEST_CALLER_CWD VV_TEST_CONFIG_ROOT VV_TEST_DATA_ROOT VV_TEST_SITE VV_TEST_DEPS_CACHE
  export VV_TEST_VENDOR_ROOT VV_TEST_LAZY_ROOT VV_TEST_PACK_ROOT

  # 在 env.sh 追加路径前，先冻结调用方提供的 runtime 根目录
  vv_roots=${VV_TEST_RUNTIME_PATHS:-}
  VV_TEST_RUNTIME_PATHS=
  vv_old_ifs=$IFS
  vv_old_flags=$-
  IFS='
'
  set -f
  for vv_value in $vv_roots; do
    VV_TEST_RUNTIME_ENTRY=$vv_value
    vv_test_runtime VV_TEST_RUNTIME_ENTRY || {
      IFS=$vv_old_ifs
      case "$vv_old_flags" in
        *f*) ;;
        *) set +f ;;
      esac
      return 1
    }
  done
  IFS=$vv_old_ifs
  case "$vv_old_flags" in
    *f*) ;;
    *) set +f ;;
  esac
  vv_binary=${NVIM_BIN:-nvim}
  case "$vv_binary" in
    */*)
      NVIM_BIN=$(vv_test_absolute "$vv_binary")
      ;;
    *)
      vv_binary=$(command -v "$vv_binary") || {
        vv_test_error "NVIM_BIN=$vv_binary: executable missing"
        return 1
      }
      NVIM_BIN=$(vv_test_absolute "$vv_binary")
      ;;
  esac
  [ -x "$NVIM_BIN" ] || {
    vv_test_error "NVIM_BIN=$NVIM_BIN: not executable"
    return 1
  }
  export NVIM_BIN
}

# 必须在准备任何依赖前运行，包括 mini.test 的 Git 操作
vv_test_clean_environment() {
  for vv_key in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$vv_key"
  done
  unset TMUX TMUX_PANE STY WINDOW KITTY_LISTEN_ON KITTY_WINDOW_ID WEZTERM_PANE
  unset NVIM NVIM_LISTEN_ADDRESS NVIM_LOG_FILE VIM VIMRUNTIME
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_GLOBAL=/dev/null
  export GIT_TERMINAL_PROMPT=0
}
