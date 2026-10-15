#!/bin/sh
# Build a private Oratcl package; never replace an installed Oracle driver.
set -eu
if [ "$#" -ne 4 ]; then
    echo "Usage: $0 ORATCL_SOURCE TCL_CONFIG_DIR TCL_INCLUDE_DIR OUTPUT_DIR" >&2
    exit 2
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_dir=$(CDPATH= cd -- "$1" && pwd)
tcl_config_dir=$(CDPATH= cd -- "$2" && pwd)
tcl_include_dir=$(CDPATH= cd -- "$3" && pwd)
mkdir -p "$4"
output_dir=$(CDPATH= cd -- "$4" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/hdb-oratcl-XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
cp -R "$source_dir" "$build_dir/source"
cd "$build_dir/source"
patch -p1 < "$script_dir/Oratcl-oci32.patch"
mkdir "$build_dir/build"
cd "$build_dir/build"
sh ../source/configure --with-tcl="$tcl_config_dir" --with-tclinclude="$tcl_include_dir"
make -j "${BUILD_JOBS:-2}"
# No make install: the destination is an isolated package directory.
cp libOratcl4.6.1.so pkgIndex.tcl "$source_dir/library/oratcl_utils.tcl" "$output_dir/"
cp "$source_dir/license.terms" "$output_dir/"
echo "Built corrected Oratcl package: $output_dir"
