#!/bin/sh
# Builds the HTML5 (wasm-web) bundle into dist/.
# Needs JDK 25 and bob.jar for Defold 1.13.1:
#   https://github.com/defold/defold/releases/download/1.13.1/bob.jar
# Environment: BOB (path to bob.jar, default ./bob.jar), JAVA (default java),
#              VARIANT (debug|release, default release).
set -e
cd "$(dirname "$0")/.."
BOB="${BOB:-./bob.jar}"
JAVA="${JAVA:-java}"
VARIANT="${VARIANT:-release}"
# keep atlases, fonts, sound components and client/assets_index.lua in sync
# with whatever is in assets/ right now
if command -v python3 >/dev/null 2>&1; then
	python3 tools/gen_defold.py
fi
"$JAVA" -jar "$BOB" --platform wasm-web --architectures wasm-web \
	--variant "$VARIANT" --archive --bundle-output dist \
	resolve distclean build bundle
echo "web bundle: $(find dist -name index.html | head -1)"
