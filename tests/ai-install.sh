#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source <(sed '/^case "${1:-}" in/,$d' warp-ai.sh)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
SOURCE_SCRIPT=$PWD/warp-ai.sh
SELF=$work/warp-ai
fetch_script() { echo 'unexpected remote download' >&2; return 1; }
install_self
cmp "$SOURCE_SCRIPT" "$SELF"
[[ -x "$SELF" ]]
# A connectivity failure must not print installation success or panel settings.
detect_arch() { :; }
install_deps() { :; }
install_wgcf() { :; }
install_wireproxy() { :; }
register_warp() { :; }
write_config() { :; }
sleep() { :; }
warp_ok() { return 1; }
check_ai() { echo unexpected-check; }
print_panel() { echo unexpected-panel; }
if do_install >"$work/output"; then echo 'FAIL: connection failure reported success'; exit 1; fi
[[ ! -s "$work/output" ]]
# Remote older versions must not replace the installed script, even with -f.
fetch_script() {
  local tmp
  tmp=$(mktemp "$work/remote.XXXXXX")
  printf '#!/bin/bash\nVERSION=1.1.1\n' >"$tmp"
  echo "$tmp"
}
before=$(sha256sum "$SELF")
if (do_update -f) >"$work/output"; then echo 'FAIL: downgrade allowed'; exit 1; fi
[[ $(sha256sum "$SELF") == "$before" ]]
printf 'PASS: local installation, failure propagation, downgrade protection\n'
