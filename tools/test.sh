#!/bin/sh
# Runs the pure-Lua test suite on both VMs the game ships on:
# Lua 5.1 (Defold HTML5) and LuaJIT (Defold desktop/mobile).
set -e
cd "$(dirname "$0")/.."
status=0
for vm in lua5.1 luajit; do
	if command -v "$vm" >/dev/null 2>&1; then
		"$vm" tools/test/run.lua "$@" || status=1
	else
		echo "missing $vm"; status=1
	fi
done
exit $status
