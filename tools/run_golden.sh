#!/usr/bin/env bash
# Runs tools/golden_trace.gd with user:// redirected to a throwaway folder, so the
# real save files are never touched.
#
# Usage: tools/run_golden.sh <fixture_dir> <output_file> [expected_file]
#   fixture_dir    folder holding copies of ai_brain.json and player_model.json
#   output_file    receives the HASH lines
#   expected_file  optional reference; the run fails if the HASH lines differ
#
# Needs GODOT to point at the console build of Godot.
set -u

# Keep in step with the scenario loops in tools/golden_trace.gd.
EXPECTED_SCENARIOS=20

if [ "$#" -lt 2 ]; then
	echo "usage: $0 <fixture_dir> <output_file> [expected_file]" >&2
	exit 2
fi
fixture_dir=$1
output_file=$2
expected_file=${3:-}

iso_root=$(mktemp -d)
trap 'rm -rf "$iso_root"' EXIT
user_dir="$iso_root/Godot/app_userdata/snakey"
mkdir -p "$user_dir/fixture"
cp "$fixture_dir/ai_brain.json" "$fixture_dir/player_model.json" "$user_dir/fixture/"
touch "$user_dir/golden_isolated.marker"

# Godot derives user:// from APPDATA on Windows. golden_trace.gd stops if the
# redirect did not take effect, because it cannot find the marker then.
win_root=$(cygpath -w "$iso_root" 2>/dev/null || echo "$iso_root")

APPDATA="$win_root" "$GODOT" --headless --path . --script res://tools/golden_trace.gd > "$output_file.log" 2>&1
status=$?
grep '^HASH ' "$output_file.log" > "$output_file"
grep -E '^(USER_DIR|INFO) |ERROR|SCRIPT ERROR|WARNING' "$output_file.log"

if [ "$status" -ne 0 ]; then
	echo "KALDI: golden_trace exit code $status (full log: $output_file.log)"
	exit 1
fi
# A script error does not change Godot's exit code, so check the log as well.
if grep -qE 'SCRIPT ERROR|Parse Error' "$output_file.log"; then
	echo "KALDI: logda script hatasi var (full log: $output_file.log)"
	exit 1
fi
scenario_count=$(wc -l < "$output_file")
if [ "$scenario_count" -ne "$EXPECTED_SCENARIOS" ]; then
	echo "KALDI: $scenario_count senaryo calisti, beklenen $EXPECTED_SCENARIOS"
	exit 1
fi
if [ -n "$expected_file" ]; then
	if diff "$expected_file" "$output_file"; then
		echo "GECTI: $(wc -l < "$output_file") senaryo referansla ayni"
	else
		echo "KALDI: hash farki var"
		exit 1
	fi
fi
