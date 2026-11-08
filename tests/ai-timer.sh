#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source <(sed '/^case "${1:-}" in/,$d' warp-ai.sh)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
SYSTEMD_DIR=$work
calls=$work/calls
systemctl() { printf '%s\n' "$*" >>"$calls"; }
: >"$SYSTEMD_DIR/$SERVICE.service"
for interval in 1h 30m 3h 1d; do
  timer_set "$interval" >/dev/null
  grep -qx "OnActiveSec=$interval" "$SYSTEMD_DIR/$TIMER_UNIT.timer"
  grep -qx "OnUnitActiveSec=$interval" "$SYSTEMD_DIR/$TIMER_UNIT.timer"
  grep -qx "ExecStart=/usr/bin/systemctl try-restart warp-ai.service" "$SYSTEMD_DIR/$TIMER_UNIT.service"
done
before=$(sha256sum "$SYSTEMD_DIR/$TIMER_UNIT.timer")
for interval in 0h -1h 1.5h 1s 01h 9999999h '' $'1h\nUnit=evil.service' '1h;id'; do
  if timer_set "$interval" >/dev/null; then echo "FAIL: invalid interval accepted"; exit 1; fi
done
[[ $(sha256sum "$SYSTEMD_DIR/$TIMER_UNIT.timer") == "$before" ]]
grep -qx 'enable warp-ai-reconnect.timer' "$calls"
grep -qx 'restart warp-ai-reconnect.timer' "$calls"
# Setting a schedule must not interrupt the running WARP service.
if grep -qE '^(restart|try-restart) warp-ai.service$' "$calls"; then exit 1; fi
timer_remove >/dev/null
[[ ! -e "$SYSTEMD_DIR/$TIMER_UNIT.timer" && ! -e "$SYSTEMD_DIR/$TIMER_UNIT.service" ]]
grep -qx 'disable --now warp-ai-reconnect.timer' "$calls"
timer_remove >/dev/null
[[ $(timer_status) == '定时重启：未开启' ]]
if timer_set 1h >/dev/null; then
  # Service still exists at this stage; verify pre-install rejection separately.
  rm "$SYSTEMD_DIR/$SERVICE.service"
fi
if timer_set 1h >/dev/null; then echo 'FAIL: missing WARP accepted'; exit 1; fi
printf 'PASS: intervals, invalid input, enable/replace/delete, missing service\n'
