#!/bin/bash
# Dev loop: rebuild whenever Sources/, Package.swift, Resources/ or scripts/ change.
# Writes the result to .dev/build.log and .dev/status so an agent can read it.
#
# Usage: ./scripts/watch-build.sh                 compile check only
#        AUTO_INSTALL=1 ./scripts/watch-build.sh  also run scripts/install.sh after a
#                                                 successful build (log: .dev/install.log)
# Ctrl-C to stop. The script restarts itself when it is edited.
cd "$(dirname "$0")/.."
mkdir -p .dev

if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found. Install the Command Line Tools: xcode-select --install" | tee .dev/build.log
  echo "fail $(date '+%F %T') no-swift" > .dev/status
  exit 1
fi
swift --version > .dev/toolchain.txt 2>&1
sw_vers >> .dev/toolchain.txt 2>&1

fingerprint() {
  find Sources Package.swift Resources scripts -type f -exec stat -f '%m %z %N' {} + 2>/dev/null | sort | md5
}

SELF="$0"
self_sum="$(md5 -q "$SELF")"
last=""
echo "👀 Watching for changes (AUTO_INSTALL=${AUTO_INSTALL:-0}, Ctrl-C to stop)…"
while true; do
  if [ "$(md5 -q "$SELF")" != "$self_sum" ]; then
    echo "↻ watch-build.sh changed, restarting"
    exec env AUTO_INSTALL="${AUTO_INSTALL:-0}" "$SELF"
  fi
  now="$(fingerprint)"
  if [ "$now" != "$last" ]; then
    sleep 1                      # let multi-file updates finish landing
    now="$(fingerprint)"
    last="$now"
    echo "building $(date '+%F %T')" > .dev/status
    echo "▶ $(date '+%T') building…"
    if swift build > .dev/build.log 2>&1; then
      result="ok"
      if [ "${AUTO_INSTALL:-0}" = "1" ]; then
        echo "installing $(date '+%F %T')" > .dev/status
        echo "   installing…"
        if ./scripts/install.sh > .dev/install.log 2>&1; then result="installed"; else result="fail-install"; fi
      fi
    else
      result="fail"
    fi
    echo "$result $(date '+%F %T')" > .dev/status
    echo "   → $result"
    [ "$result" = "fail" ] && grep -E "error:" .dev/build.log | head -5
  fi
  sleep 2
done
