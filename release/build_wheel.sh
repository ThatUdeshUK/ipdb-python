#!/usr/bin/env bash
#
# Builds Linux (manylinux) wheels for the ipdb Python package, looping over
# every supported CPython version for a single target architecture.
#
# This is what .github/workflows/packaging_wheels.yml calls once per
# architecture (native runners only, no cross-arch emulation) instead of
# expanding a python x arch matrix into one CI job per cell. It can also be
# run locally (with `uv` installed) to build wheels for the host arch.
#
# Usage:
#   ./release/build_wheel.sh <x86_64|aarch64> [--minimal] [--version vX.Y.Z[-postN|-rcN]]
#
# --version pins the exact package version to build (via OVERRIDE_GIT_DESCRIBE,
# see duckdb_packaging/setuptools_scm_version.py), instead of letting
# setuptools_scm derive a .devN version from the current git history. Used for
# release builds, e.g. --version v1.1.0.
#
# All wheels are collected into wheelhouse/ (cibuildwheel's default output
# dir), one build per CPython version, accumulating across the loop.
#
# Relevant CIBW_* environment variables (CIBW_TEST_SKIP, CIBW_TEST_SOURCES,
# CIBW_BEFORE_TEST, CIBW_TEST_COMMAND, CIBW_ENVIRONMENT, ...) are inherited
# from the calling environment and apply to every version built here.

set -euo pipefail

# Pin the cibuildwheel version so wheel builds are reproducible; bump
# deliberately when upgrading.
CIBW_VERSION="${CIBW_VERSION:-3.2.0}"

# Every CPython version we ship wheels for. Keep in sync with the `python:`
# list that used to live in packaging_wheels.yml's matrix.
ALL_PYTHON_VERSIONS=(cp39 cp310 cp311 cp312 cp313 cp314)
# Minimal sanity-check subset used for `inputs.minimal` runs (oldest +
# newest supported version).
MINIMAL_PYTHON_VERSIONS=(cp39 cp314)

usage() {
  echo "Usage: $0 <x86_64|aarch64> [--minimal] [--version vX.Y.Z[-postN|-rcN]]" >&2
  exit 1
}

ARCH="${1:-}"
[[ -n "$ARCH" ]] || usage
shift

case "$ARCH" in
  x86_64 | aarch64) ;;
  *)
    echo "error: unsupported architecture '$ARCH' (expected x86_64 or aarch64)" >&2
    exit 1
    ;;
esac

MINIMAL="false"
VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --minimal)
      MINIMAL="true"
      shift
      ;;
    --version)
      VERSION="${2:-}"
      [[ -n "$VERSION" ]] || { echo "error: --version requires an argument, e.g. --version v1.1.0" >&2; exit 1; }
      shift 2
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage
      ;;
  esac
done

if [[ -n "$VERSION" && ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(post|rc)[0-9]+)?$ ]]; then
  echo "error: invalid --version '$VERSION' (expected vX.Y.Z, vX.Y.Z-postN or vX.Y.Z-rcN)" >&2
  exit 1
fi

if [[ "$MINIMAL" == "true" ]]; then
  PYTHON_VERSIONS=("${MINIMAL_PYTHON_VERSIONS[@]}")
else
  PYTHON_VERSIONS=("${ALL_PYTHON_VERSIONS[@]}")
fi

command -v uv >/dev/null 2>&1 || {
  echo "error: uv is required (https://docs.astral.sh/uv/) but was not found on PATH" >&2
  exit 1
}

if [[ -n "$VERSION" ]]; then
  echo "Pinning version to ${VERSION} (via OVERRIDE_GIT_DESCRIBE)"
  # Append to any CIBW_ENVIRONMENT already set by the caller, rather than clobbering it.
  export CIBW_ENVIRONMENT="${CIBW_ENVIRONMENT:-} OVERRIDE_GIT_DESCRIBE=${VERSION}"
  CIBW_ENVIRONMENT="${CIBW_ENVIRONMENT# }"
fi

echo "Building manylinux_${ARCH} wheels for: ${PYTHON_VERSIONS[*]}"

export CIBW_ARCHS="$ARCH"

for python in "${PYTHON_VERSIONS[@]}"; do
  build="${python}-manylinux_${ARCH}"
  echo "::group::Building ${build}"
  CIBW_BUILD="$build" uvx "cibuildwheel==${CIBW_VERSION}"
  echo "::endgroup::"
done

built=$(ls wheelhouse/*.whl 2>/dev/null | wc -l | tr -d ' ')
echo "Built ${built} wheel(s) in wheelhouse/"
