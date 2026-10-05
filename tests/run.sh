#!/bin/sh
# Utils defaults to this checkout; all suite behavior stays in the shared runner.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

. "$repo/dev/test/paths.sh"
VV_TEST_CALLER_CWD=$(pwd -P)
VV_UTILS=$(vv_test_source_path VV_UTILS "$repo" dev/test/run.sh dev/test/paths.sh lua/vv-utils/init.lua)
export VV_UTILS

exec sh "$VV_UTILS/dev/test/run.sh" "$repo" "$@"
