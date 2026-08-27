#!/bin/bash
# Copy the shared libraries that the given trees actually load into $DEST,
# keeping their absolute paths, so they can be layered onto a distroless image
# that has no package manager to install them with.
#
# Usage: collect-libs.sh <dest-rootfs> <dir-to-scan> [dir-to-scan ...]
set -euo pipefail

DEST=${1:?usage: collect-libs.sh <dest-rootfs> <dir-to-scan>...}
shift

# The distroless base ships glibc, and its ld.so has to stay paired with its own
# libc, so never overwrite that set.
GLIBC='ld-linux-x86-64\.so\.2|libc\.so\.6|libm\.so\.6|libmvec\.so\.1|libdl\.so\.2|libpthread\.so\.0|librt\.so\.1|libresolv\.so\.2|libutil\.so\.1|libanl\.so\.1|libnsl\.so\.1|libBrokenLocale\.so\.1|libthread_db\.so\.1|libcrypt\.so\.1'

# Libraries Firefox reaches for with dlopen(), which never show up in ldd output.
DLOPENED=(
    libasound.so.2        # cubeb audio backend
    libcups.so.2          # printing
    libdbus-glib-1.so.2   # desktop integration
)

is_elf() {
    [ "$(head -c 4 -- "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]
}

# A resolved library that lives inside one of the trees being scanned is
# already shipped as part of that tree -- numpy's bundled OpenBLAS reaches its
# extension modules through an $ORIGIN RPATH, for instance. Copying it again
# would put a second 27 MB copy at a path nothing loads from.
is_inside_scanned_tree() {
    local lib=$1 root
    for root in "${SCAN_ROOTS[@]}"; do
        case "$lib" in "$root"/*) return 0 ;; esac
    done
    return 1
}

SCAN_ROOTS=("$@")
elf_files=()
while IFS= read -r -d '' file; do
    is_elf "$file" && elf_files+=("$file")
done < <(find "$@" -type f ! -path '*/fonts/*' -print0)

echo "collect-libs: scanning ${#elf_files[@]} ELF files" >&2

{
    for file in "${elf_files[@]}"; do
        ldd "$file" 2>/dev/null || true
    done
    for soname in "${DLOPENED[@]}"; do
        ldconfig -p | awk -v s="$soname" '$1 == s { print s " => " $NF " (0x0)" }'
    done
} | sed -n 's|.* => \(/[^ ]*\) (0x[0-9a-f]*)$|\1|p' | sort -u |
    grep -Ev "/($GLIBC)\$" > /tmp/resolved.txt

: > /tmp/libs.txt
while IFS= read -r lib; do
    is_inside_scanned_tree "$lib" || echo "$lib" >> /tmp/libs.txt
done < /tmp/resolved.txt

while IFS= read -r lib; do
    # -D creates parent dirs; the copy follows the SONAME symlink so the real
    # object lands at the path the loader looks for.
    install -D "$lib" "$DEST$lib"
done < /tmp/libs.txt

echo "collect-libs: copied $(wc -l < /tmp/libs.txt) libraries into $DEST" >&2
