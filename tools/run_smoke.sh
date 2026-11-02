#!/usr/bin/env bash
# Runs tools/smoke_test.gd with user:// redirected to a throwaway folder, so the
# real save files are never touched.
#
# Usage: tools/run_smoke.sh
# Needs GODOT to point at the console build of Godot.
# Exit code: 0 pass, 1 failure, 2 setup problem or refusal.
set -u

TIMEOUT_SECONDS=120

if [ -z "${GODOT:-}" ] || [ ! -x "$GODOT" ]; then
	echo "GODOT is unset or not executable: '${GODOT:-}'" >&2
	exit 2
fi

iso_root=$(mktemp -d)
trap 'rm -rf "$iso_root"' EXIT
user_dir="$iso_root/Godot/app_userdata/snakey"
mkdir -p "$user_dir"
touch "$user_dir/smoke_isolated.marker"

# Godot derives user:// from APPDATA on Windows. smoke_test.gd stops with exit
# code 2 if the redirect did not take effect, because it cannot find the marker.
win_root=$(cygpath -w "$iso_root" 2>/dev/null || echo "$iso_root")

log_file="$iso_root/smoke.log"
# The script's own watchdog cannot fire if a scene hangs the main thread.
APPDATA="$win_root" timeout "$TIMEOUT_SECONDS" "$GODOT" --headless --path . --script res://tools/smoke_test.gd > "$log_file" 2>&1
status=$?

# A script error does not change Godot's exit code, so check the log as well.
if [ "$status" -eq 0 ] && grep -qE 'SCRIPT ERROR|Parse Error' "$log_file"; then
	echo "KALDI: logda script hatasi var"
	status=1
fi
# Exit 0 alone proves nothing: Godot also exits 0 if the script never ran.
if [ "$status" -eq 0 ] && ! grep -q '^SMOKE GECTI' "$log_file"; then
	echo "KALDI: SMOKE GECTI satiri yok, test calismamis olabilir"
	status=1
fi

if [ "$status" -ne 0 ]; then
	cat "$log_file"
	echo "KALDI: smoke_test exit code $status"
	exit "$status"
fi
grep '^SMOKE ' "$log_file"
