#!/bin/sh
# Build a private TLS-enabled OBCI client from vendor objects. Do not overwrite
# the installed libobci.so, libobclient or the native Oracle client.
set -eu
if [ "$#" -ne 5 ]; then
    echo "Usage: $0 OBCI_STATIC_ARCHIVE OBCLIENT_LIB_DIR TCL_CONFIG_DIR TCL_INCLUDE_DIR OUTPUT_DIR" >&2
    exit 2
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
archive=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
client_dir=$(CDPATH= cd -- "$2" && pwd)
tcl_config_dir=$(CDPATH= cd -- "$3" && pwd)
tcl_include_dir=$(CDPATH= cd -- "$4" && pwd)
mkdir -p "$5"
output_dir=$(CDPATH= cd -- "$5" && pwd)
. "$tcl_config_dir/tclConfig.sh"
# A Tcl source build's config can retain its future installation prefix.
stub_library=$tcl_config_dir/libtclstub.a
if [ -f "$stub_library" ]; then TCL_STUB_LIB_SPEC=$stub_library; fi
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/hdb-obci-tls-XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
cd "$build_dir"
# libobci.a also includes libobclient/OpenSSL. Use only its OCI implementation,
# resolving the remaining client APIs through the supplied shared libobclient.
ar x "$archive"
for object in obclient_ociap.c.o obxa.c.o hashmap.c.o list.c.o; do
    test -f "$object" || { echo "Unsupported OBCI archive: missing $object" >&2; exit 1; }
done
${CC:-cc} -std=c11 -Wall -Wextra -Werror -fPIC -shared -DUSE_TCL_STUBS -DTCL_THREADS=1 \
    -I"$tcl_include_dir" "$script_dir/obci-tls.c" oci_*.o obclient_ociap.c.o obxa.c.o hashmap.c.o list.c.o \
    -Wl,--wrap=mysql_real_connect -Wl,-z,defs -Wl,-rpath,"$client_dir" \
    -L"$client_dir" -lobclnt $TCL_STUB_LIB_SPEC -lm -ldl -lpthread -o libhdbobcitls.so
cp libhdbobcitls.so "$output_dir/"
echo "Built OBCI TLS client: $output_dir/libhdbobcitls.so"
