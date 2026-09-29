#!/bin/sh
# Builds the HTML5 (wasm-web) bundle into dist/.
# Needs python3, JDK 25 and bob.jar for Defold 1.13.1:
#   https://github.com/defold/defold/releases/download/1.13.1/bob.jar
# Environment: BOB (path to bob.jar, default ./bob.jar), JAVA (default java),
#              VARIANT (debug|release, default release),
#              SKIP_GEN=1 to build without re-running tools/gen_defold.py
#              (only when the generated files are known to be up to date).
# A debug bundle carries dist/GLOW/DEBUG_BUILD_DO_NOT_PUBLISH: it has cheat
# keys and the QA bridge (localhost only) and must never go to a portal.
set -e
cd "$(dirname "$0")/.."
BOB="${BOB:-./bob.jar}"
JAVA="${JAVA:-java}"
VARIANT="${VARIANT:-release}"
# keep atlases, fonts, sound components and client/assets_index.lua in sync
# with whatever is in assets/ right now
if [ "${SKIP_GEN:-0}" = "1" ]; then
	echo "SKIP_GEN=1: not running tools/gen_defold.py"
elif command -v python3 >/dev/null 2>&1; then
	python3 tools/gen_defold.py
else
	echo "error: python3 is needed to run tools/gen_defold.py (or set SKIP_GEN=1)" >&2
	exit 1
fi
"$JAVA" -jar "$BOB" --platform wasm-web --architectures wasm-web \
	--variant "$VARIANT" --archive --bundle-output dist \
	resolve distclean build bundle
out="$(dirname "$(find dist -name index.html | head -1)")"
rm -f "$out/DEBUG_BUILD_DO_NOT_PUBLISH"
if [ "$VARIANT" = "debug" ]; then
	echo "debug bundle: cheat keys and the QA bridge are in it. Never publish it." > "$out/DEBUG_BUILD_DO_NOT_PUBLISH"
	echo "WARNING: debug bundle in $out: do not upload it to a portal"
fi
echo "web bundle ($VARIANT): $out/index.html"
