#!/usr/bin/env bash
#
# Builds a source distribution (sdist) for the ipdb Python package, installs
# it into a throwaway venv to sanity-check it, and optionally runs the test
# suite against that install.
#
# This is what .github/workflows/packaging_sdist.yml does, factored out so
# it can also be run locally (with `uv` installed).
#
# Usage:
#   ./release/build_sdist.sh [--version vX.Y.Z[-postN|-rcN]] [--test none|fast|all]
#
# --version pins the exact package version to build (via OVERRIDE_GIT_DESCRIBE,
# see duckdb_packaging/setuptools_scm_version.py), instead of letting
# setuptools_scm derive a .devN version from the current git history.
#
# --test controls whether (and how much of) the test suite runs against the
# installed sdist: 'none' (default) just installs it and prints the version,
# 'fast' runs tests/fast, 'all' runs the full tests/ suite.
#
# Prerequisite (matches CI): curl and libcurl development headers must be
# installed (e.g. `apt-get install curl libcurl4-openssl-dev libssl-dev
# pkg-config` on Debian/Ubuntu), since building DuckDB's HTTPFS support needs
# them.
#
# The built sdist is written to dist/*.tar.gz. When run in GitHub Actions
# (i.e. $GITHUB_OUTPUT is set), pkg_version and duckdb_version step outputs
# are written too.

set -euo pipefail

usage() {
  echo "Usage: $0 [--version vX.Y.Z[-postN|-rcN]] [--test none|fast|all]" >&2
  exit 1
}

VERSION=""
TEST="none"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      [[ -n "$VERSION" ]] || { echo "error: --version requires an argument, e.g. --version v1.1.0" >&2; exit 1; }
      shift 2
      ;;
    --test)
      TEST="${2:-}"
      [[ -n "$TEST" ]] || { echo "error: --test requires an argument (none, fast or all)" >&2; exit 1; }
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

case "$TEST" in
  none | fast | all) ;;
  *)
    echo "error: invalid --test '$TEST' (expected none, fast or all)" >&2
    exit 1
    ;;
esac

command -v uv >/dev/null 2>&1 || {
  echo "error: uv is required (https://docs.astral.sh/uv/) but was not found on PATH" >&2
  exit 1
}

if [[ -n "$VERSION" ]]; then
  echo "Pinning version to ${VERSION} (via OVERRIDE_GIT_DESCRIBE)"
  export OVERRIDE_GIT_DESCRIBE="$VERSION"
fi

echo "Building sdist..."
uv build --sdist

sdist_rel="$(ls -t dist/ipdb-*.tar.gz | head -1)"
repo_root="$(pwd)"
sdist_abs="${repo_root}/${sdist_rel}"
echo "Built ${sdist_rel}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "Installing sdist into a throwaway venv..."
cd "$workdir"
# Ignore any virtualenv active in the calling shell (uv prefers VIRTUAL_ENV
# over a freshly created local .venv, which would silently "install" into
# that env instead -- and skip the install entirely if it already has ipdb).
unset VIRTUAL_ENV UV_PROJECT_ENVIRONMENT
uv venv --quiet
export VIRTUAL_ENV="${workdir}/.venv"
uv pip install --quiet --reinstall-package ipdb "$sdist_abs"

pkg_version="$(.venv/bin/python -c 'import ipdb; print(ipdb.__version__)')"
duckdb_version="$(.venv/bin/python -c 'import ipdb; print(ipdb.__duckdb_version__)')"
echo "Installed ipdb ${pkg_version} (bundled duckdb ${duckdb_version})"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "pkg_version=${pkg_version}"
    echo "duckdb_version=${duckdb_version}"
  } >> "$GITHUB_OUTPUT"
fi

if [[ "$TEST" == "none" ]]; then
  exit 0
fi

echo "Installing test dependencies..."
uv export --directory "$repo_root" --only-group test --no-emit-project --quiet --output-file pylock.toml
uv pip install --quiet -r pylock.toml

tests_dir="${repo_root}/tests"
[[ "$TEST" == "fast" ]] && tests_dir="${tests_dir}/fast"

echo "Running ${TEST} test suite against installed sdist..."
uv run --verbose pytest -c "${repo_root}/pyproject.toml" "$tests_dir"
