#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build-local.sh — full local build-and-serve cycle for xeus-r JupyterLite
#
# Usage:
#   ./build-local.sh              # full rebuild (recreate envs + build)
#   ./build-local.sh --skip-envs  # skip env recreation (code-only changes)
# ---------------------------------------------------------------------------

SKIP_ENVS=false
for arg in "$@"; do
  case "$arg" in
    --skip-envs) SKIP_ENVS=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-$HOME/micromamba}"
BUILD_ENV="xeus-r-wasm-build"
HOST_ENV="xeus-r-wasm-host"
BUILD_PREFIX="$MAMBA_ROOT_PREFIX/envs/$BUILD_ENV"
PREFIX="$MAMBA_ROOT_PREFIX/envs/$HOST_ENV"

# Detect CPU count
if command -v sysctl &>/dev/null; then
  NCPUS=$(sysctl -n hw.ncpu)
elif command -v nproc &>/dev/null; then
  NCPUS=$(nproc)
else
  NCPUS=4
fi

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

LIBRARIES=(jsonlite rlang base64enc digest fastmap htmltools cli glue vctrs)

# Track whether we swapped .so files so we can restore on failure
LIBS_SWAPPED=false

cleanup() {
  if $LIBS_SWAPPED; then
    echo "--- Restoring wasm .so files ---"
    for lib in "${LIBRARIES[@]}"; do
      local so="$PREFIX/lib/R/library/$lib/libs/$lib.so"
      if [[ -f "$so.bak" ]]; then
        rm -f "$so"
        mv "$so.bak" "$so"
      fi
    done
    LIBS_SWAPPED=false
  fi
}
trap cleanup EXIT

# ---- Step 1: Recreate conda environments ---------------------------------
if ! $SKIP_ENVS; then
  echo "=== Recreating conda environments ==="
  micromamba env remove -n "$BUILD_ENV" -y 2>/dev/null || true
  rm -rf "$BUILD_PREFIX"
  micromamba create -f environment-wasm-build.yml -n "$BUILD_ENV" -y

  micromamba env remove -n "$HOST_ENV" -y 2>/dev/null || true
  rm -rf "$PREFIX"
  micromamba create -f environment-wasm-host.yml -n "$HOST_ENV" --platform=emscripten-wasm32 -y
else
  echo "=== Skipping env recreation (--skip-envs) ==="
fi

# Verify envs exist
if [[ ! -d "$BUILD_PREFIX" ]]; then
  echo "ERROR: Build environment not found at $BUILD_PREFIX" >&2
  exit 1
fi
if [[ ! -d "$PREFIX" ]]; then
  echo "ERROR: Host environment not found at $PREFIX" >&2
  exit 1
fi

# ---- Step 2: Patch Makeconf ----------------------------------------------
echo "=== Patching Makeconf ==="
echo "R_HOME=${PREFIX}/lib/R"                  > "$BUILD_PREFIX/lib/R/etc/Makeconf"
cat "$PREFIX/lib/R/etc/Makeconf"              >> "$BUILD_PREFIX/lib/R/etc/Makeconf"

# ---- Step 3: Swap .so files (wasm → native for R CMD INSTALL) -------------
echo "=== Swapping .so files (wasm → native) ==="
for lib in "${LIBRARIES[@]}"; do
  so="$PREFIX/lib/R/library/$lib/libs/$lib.so"
  echo "  Backup $lib"
  mv "$so" "$so.bak"
  cp "$BUILD_PREFIX/lib/R/library/$lib/libs/$lib.so" "$so"
done
LIBS_SWAPPED=true

# ---- Step 4: Install hera ------------------------------------------------
echo "=== Installing hera ==="
R_PROFILE_USER="" "$BUILD_PREFIX/bin/R" CMD INSTALL ./hera \
  --no-byte-compile --no-test-load \
  --library="$PREFIX/lib/R/library/"

# ---- Step 5: Restore .so files -------------------------------------------
echo "=== Restoring wasm .so files ==="
for lib in "${LIBRARIES[@]}"; do
  so="$PREFIX/lib/R/library/$lib/libs/$lib.so"
  rm "$so"
  mv "$so.bak" "$so"
done
LIBS_SWAPPED=false

# ---- Step 6: Build xeus-r ------------------------------------------------
echo "=== Building xeus-r ==="

# Out-of-source build in build/ (gitignored)
rm -rf build
mkdir build

micromamba run -n "$BUILD_ENV" bash -c "
  set -euo pipefail
  unset LDFLAGS CFLAGS CXXFLAGS CPPFLAGS

  export PREFIX=\"$PREFIX\"
  export CMAKE_PREFIX_PATH=\"$PREFIX\"
  export CMAKE_SYSTEM_PREFIX_PATH=\"$PREFIX\"

  cd build

  emcmake cmake .. \\
    -DCMAKE_BUILD_TYPE=Release \\
    -DCMAKE_PREFIX_PATH=\"$PREFIX\" \\
    -DCMAKE_INSTALL_PREFIX=\"$PREFIX\" \\
    -DCMAKE_FIND_ROOT_PATH=\"$PREFIX\" \\
    -DXEUS_R_EMSCRIPTEN_WASM_BUILD=ON

  emmake make -j $NCPUS install
"

# ---- Step 7: Build JupyterLite site --------------------------------------
echo "=== Building JupyterLite site ==="
rm -rf dist/

micromamba run -n "$BUILD_ENV" \
  jupyter lite build \
    --XeusAddon.prefix="$PREFIX" \
    --XeusAddon.mounts="$PREFIX/lib/R/library/hera:/lib/R/library/hera" \
    --XeusAddon.default_channels=https://repo.prefix.dev/emscripten-forge-4x \
    --XeusAddon.default_channels=https://repo.prefix.dev/conda-forge \
    --contents README.md \
    --contents notebooks/xeus-r.ipynb \
    --output-dir dist

# ---- Step 8: Copy shared libs workaround ---------------------------------
echo "=== Copying shared libs (jupyterlite-xeus path workaround) ==="
KERNEL_DIR="dist/xeus/$HOST_ENV/xr"
STATIC_DIR="dist/extensions/@jupyterlite/xeus-extension/static"

for lib in libR.so libRblas.so libRlapack.so libz.so; do
  if [[ -f "$KERNEL_DIR/$lib" ]]; then
    cp "$KERNEL_DIR/$lib" "$STATIC_DIR/$lib"
    echo "  Copied $lib"
  else
    echo "  WARNING: $KERNEL_DIR/$lib not found, skipping"
  fi
done

# ---- Step 9: Serve -------------------------------------------------------
echo ""
echo "=== Build complete. Serving at http://localhost:8888 ==="
python3 -m http.server 8888 --directory dist
