# 仅声明已有依赖；这里不安装依赖，也不执行测试行为
vv_test_dependency VV_TEST_ICONS vv-icons.nvim lua/vv-icons/init.lua
# 在隔离 HOME 前定位真实 Cargo 二进制（rustup shim 需要原始 HOME）
if [ -z "${VV_TEST_TOOLCHAIN_BIN:-}" ] && command -v rustup >/dev/null 2>&1; then
  vv_cargo=$(rustup which cargo 2>/dev/null || :)
  if [ -n "$vv_cargo" ]; then
    VV_TEST_TOOLCHAIN_BIN=$(dirname -- "$vv_cargo")
  fi
fi

if [ -n "${VV_TEST_TOOLCHAIN_BIN:-}" ]; then
  vv_test_path VV_TEST_TOOLCHAIN_BIN "$VV_TEST_TOOLCHAIN_BIN" cargo rustc
  PATH="$VV_TEST_TOOLCHAIN_BIN:$PATH"
  export PATH
fi
