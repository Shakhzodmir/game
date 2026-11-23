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
# assets/gen/web.settings (tools/gen_defold.py): the web archive leaves out the pictures of every district but the
# first one; they ship below as plain files in packs/ and the game downloads them when the player gets there
"$JAVA" -jar "$BOB" --platform wasm-web --architectures wasm-web \
	--variant "$VARIANT" --archive --settings assets/gen/web.settings --bundle-output dist \
	resolve distclean build bundle
out="$(dirname "$(find dist -name index.html | head -1)")"
# the remote pictures (assets/gen/web_packs.txt lists them): packs/<path under assets/images>, next to index.html
rm -rf "$out/packs"
packs=0
while IFS= read -r src || [ -n "$src" ]; do
	src="$(printf '%s' "$src" | tr -d '\r')"
	[ -n "$src" ] || continue
	dst="$out/packs/${src#assets/images/}"
	mkdir -p "$(dirname "$dst")"
	cp "$src" "$dst"
	packs=$((packs + 1))
done < assets/gen/web_packs.txt
echo "remote pictures: $packs files in $out/packs"
# the service worker that keeps them in the browser across releases (registered by web/engine_template.html)
cp web/packs_sw.js "$out/"
# accounts (WP-10): the browser bridge and the public provider configuration sit next to index.html
cp web/auth_config.js web/glow_auth.js "$out/"
# the phone-side check of the sign-in with Google (https://shakhzodmir.github.io/game/auth_test.html): runs the same Firebase
# calls in a separate app instance and shows what the browser does, step by step. Next to it: our own sign-in with Google
# (glow_oidc.js, the shared core, and auth_return.html, the page Google sends the player back to; its address is registered
# at Google, so the file name must not change)
cp web/auth_test.html web/auth_echo.html web/auth_return.html web/glow_oidc.js "$out/"
# the site's own pages (WP-18): the privacy policy (the game links it as ./privacy.html) and the 404 page that
# GitHub Pages serves for any address the site does not have
cp web/privacy.html web/404.html "$out/"
# the app icon (tools/art/make_app_icon.py) and the web app manifest
cp web/apple-touch-icon.png web/icon-192.png web/icon-512.png web/favicon.png web/manifest.webmanifest "$out/"
rm -f "$out/DEBUG_BUILD_DO_NOT_PUBLISH"
if [ "$VARIANT" = "debug" ]; then
	echo "debug bundle: cheat keys and the QA bridge are in it. Never publish it." > "$out/DEBUG_BUILD_DO_NOT_PUBLISH"
	echo "WARNING: debug bundle in $out: do not upload it to a portal"
fi
echo "web bundle ($VARIANT): $out/index.html"
