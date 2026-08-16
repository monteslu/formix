#!/usr/bin/env bash
# Repack the cart. Regenerates assets.index first: a stale index is a
# directory listing that silently omits a file.
#
# NO HARDCODED PATHS. Everything resolves from this script's own location or
# from the environment, so the same script runs on a dev box and on a CI
# runner that has never heard of any particular home directory.
#
#   WASMCART_LUA  a wasmcart-lua checkout (for the engine + gen-asset-index)
#                 default: ../wasmcart-lua relative to this repo
#   ENGINE        an explicit engine.wasm, overriding WASMCART_LUA's build/
#   WASMCART_PACK the packer. Default resolves the npm 'wasmcart' package,
#                 so CI can 'npm i wasmcart' instead of cloning it.
#
# The resolution literals below (1920x1080) are one of exactly four places
# the screen size may appear -- see docs/DEVPLAN.md section 6. The others are
# app/conf.lua, app/manifest.json and app/render/viewport.lua.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"

WASMCART_LUA="${WASMCART_LUA:-$HERE/../wasmcart-lua}"
ENGINE="${ENGINE:-$WASMCART_LUA/build/engine.wasm}"
[ -f "$ENGINE" ] || { echo "no engine at $ENGINE (set ENGINE or WASMCART_LUA)" >&2; exit 1; }

# the packer: an explicit path, else the npm package, else a sibling checkout
if [ -z "${WASMCART_PACK:-}" ]; then
  WASMCART_PACK="$(node -e "process.stdout.write(require.resolve('wasmcart/bin/wasmcart-pack.js'))" 2>/dev/null || true)"
fi
[ -n "${WASMCART_PACK:-}" ] || WASMCART_PACK="$HERE/../wasmcart/bin/wasmcart-pack.js"
[ -f "$WASMCART_PACK" ] || { echo "no packer at $WASMCART_PACK (npm i wasmcart)" >&2; exit 1; }

# --open packs the GATE cart: identical, plus an `opengarden` marker that
# boots straight into the generated map instead of the campaign. Same
# mechanism as app/testmode, and like it the marker is never committed.
if [ "${1:-}" = "--open" ]; then
  : > "$HERE/app/opengarden"
else
  rm -f "$HERE/app/opengarden"
fi

cp "$ENGINE" "$HERE/main.wasm"
"$WASMCART_LUA/tools/gen-asset-index.sh" "$HERE/app" > /dev/null

# NOTE: no --pointer flag. It used to be a manifest key; current wasmcart
# has the CART declare its own input needs, and the wasmcart-lua engine
# always sets WC_FLAG_POINTER in wc_info_t (runtime.c). Passing --pointer
# now only prints a deprecation warning.
node "$WASMCART_PACK" \
  --wasm "$HERE/main.wasm" --assets "$HERE/app" \
  --name "Formix" --width 1920 --height 1080 \
  -o "$HERE/formix.wasc" > /dev/null
echo "packed $(du -h "$HERE/formix.wasc" | cut -f1)"
