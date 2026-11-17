#!/bin/sh
# Build the Oracle-mode database binding against the official libobclient SDK.
set -eu
if [ "$#" -ne 4 ]; then
    echo "Usage: $0 TCL_INCLUDE_DIR TCL_STUB_LIBRARY OBCLIENT_HOME OUTPUT_DIR" >&2
    exit 2
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/../../../.." && pwd)
tcl_include=$(CDPATH= cd -- "$1" && pwd)
tcl_stub=$2
client_home=$(CDPATH= cd -- "$3" && pwd)
mkdir -p "$4"
output_dir=$(CDPATH= cd -- "$4" && pwd)
test -f "$tcl_include/tcl.h"
test -f "$tcl_stub"
test -f "$client_home/include/mysql.h"
test -f "$client_home/lib/libobclnt.so.2"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -O2 -fPIC -shared \
    -DUSE_TCL_STUBS -DTCL_THREADS -I"$tcl_include" -I"$client_home/include" \
    "$repo_dir/src/oceanbase/oracle/oboracle.c" "$tcl_stub" \
    "$client_home/lib/libobclnt.so.2" -pthread -Wl,-rpath,'$ORIGIN' \
    -o "$output_dir/liboboracle.so"
cp "$repo_dir/src/oceanbase/oracle/pkgIndex.tcl" "$output_dir/pkgIndex.tcl"
echo "Built oboracle 1.0: $output_dir (requires official libobclnt.so.2 on the library path)"
