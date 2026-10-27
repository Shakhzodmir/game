#!/bin/sh
# Syntax check of every Lua source, Defold scripts included (they are plain
# Lua), for both VMs the game ships on: Lua 5.1 (HTML5) and LuaJIT (mobile).
# There is no local Defold build in the dev container, so this is the quick
# guard against a typo breaking the whole bundle. Usage:
#   ./tools/check_syntax.sh            # whole repository
#   ./tools/check_syntax.sh FILE...    # only these files
cd "$(dirname "$0")/.."
if [ "$#" -gt 0 ]; then
	files="$*"
else
	files=$(find . -path ./dist -prune -o -path ./build -prune -o -path ./.git -prune -o \
		\( -name '*.lua' -o -name '*.script' -o -name '*.gui_script' -o -name '*.render_script' \) -print | sort)
fi
status=0
for f in $files; do
	if ! luac5.1 -p "$f" 2>/tmp/glow_syntax.err; then
		echo "Lua 5.1: $(cat /tmp/glow_syntax.err)"; status=1
	fi
	if ! luajit -bl "$f" >/dev/null 2>/tmp/glow_syntax.err; then
		echo "LuaJIT: $(cat /tmp/glow_syntax.err)"; status=1
	fi
done
[ "$status" = 0 ] && echo "syntax ok"
exit $status
