#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "$script_dir/common.sh"
ob_tprocc_init "$script_dir"

"$HAMMERDBCLI" auto "$script_dir/build.tcl" | tee "$TMP/build.log"

