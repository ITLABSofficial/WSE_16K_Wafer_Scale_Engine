#!/bin/bash
# vvp $finish(1) ve [FAIL] satirlarinda exit!=0 donmez; bu sarmalayici basarisizligi make'e iletir.
[ -n "$1" ] && [ -f "$1" ] && sync -f "$1" 2>/dev/null
log=$(mktemp); trap 'rm -f "$log"' EXIT
vvp "$@" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}
[ "$rc" -ne 0 ] && exit "$rc"
if grep -qE '\[FAIL\]|FAILED WITH|\[FALSE\]|MISMATCH|TOTAL FAILS: [1-9]' "$log"; then
  echo ">>> vvp_strict: testbench basarisizlik bildirdi: $1" >&2; exit 1
fi
