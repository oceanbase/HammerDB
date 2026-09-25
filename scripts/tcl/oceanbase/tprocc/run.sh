#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "$script_dir/common.sh"
ob_tprocc_init "$script_dir"

run_id=$(date -u +%Y%m%dT%H%M%SZ)
"$HAMMERDBCLI" auto "$script_dir/run.tcl" | tee "$TMP/run-$run_id.log"

