#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
godot_bin="${GODOT_BIN:-}"
if [[ -z "$godot_bin" ]]; then
	for candidate in godot godot4 /opt/homebrew/bin/godot /Applications/Godot.app/Contents/MacOS/Godot; do
		if command -v "$candidate" >/dev/null 2>&1; then
			godot_bin="$(command -v "$candidate")"
			break
		fi
	done
fi
if [[ -z "$godot_bin" || ! -x "$godot_bin" ]]; then
	print -u2 "Godot executable not found"
	exit 2
fi

for mode in startup room_build entry_memory; do
	AI_TOWN_PROVIDER_TEST_NO_NETWORK=1 \
	AI_TOWN_INTERIOR_PERF_MODE="$mode" \
		"$godot_bin" \
		--headless \
		--path "$project_root" \
		--script res://tests/town_interior_performance_probe.gd
done
