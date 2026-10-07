#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mode="${1:-build}"
if [[ $# -gt 1 ]]; then
  printf '%s\n' 'Usage: ./build.sh [build|release|test|help]' >&2
  exit 2
fi
case "$mode" in
  build|release|test) ;;
  help|--help|-h)
    printf '%s\n' 'Usage: ./build.sh [build|release|test|help]' \
      '  build    Compile a development binary (default).' \
      '  release  Compile an optimized binary.' \
      '  test     Compile and run Swift checks and CLI integration tests.' \
      'Output: build/app-clone'
    exit 0
    ;;
  *) printf 'Unknown build mode: %s\n' "$mode" >&2; exit 2 ;;
esac
if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'app-clone requires macOS 14 or later.' >&2
  exit 1
fi
if [[ "$mode" == test ]] && ! command -v python3 >/dev/null; then
  printf '%s\n' 'Python 3 is required to run the integration tests.' >&2
  exit 1
fi

# Resolve both tools from the selected Apple developer directory to avoid mixing SDKs.
compiler="${APP_CLONE_SWIFTC:-$(xcrun --find swiftc)}"
sdk="${APP_CLONE_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
arch="$(uname -m)"
mkdir -p build/module-cache
flags=(-sdk "$sdk" -target "${arch}-apple-macosx14.0" -swift-version 6
  -module-cache-path "$PWD/build/module-cache" -warnings-as-errors)
if [[ "$mode" == release ]]; then flags+=(-O); fi
if [[ "$mode" == test ]]; then flags+=(-enable-testing); fi

"$compiler" "${flags[@]}" -parse-as-library -emit-library -static -emit-module \
  -module-name appclonecore -emit-module-path build/appclonecore.swiftmodule \
  sources/core/*.swift -o build/libappclonecore.a
"$compiler" "${flags[@]}" -parse-as-library -I build -L build -lappclonecore \
  sources/cli/*.swift -o build/app-clone

if [[ "$mode" == test ]]; then
  "$compiler" "${flags[@]}" -parse-as-library -I build -L build -lappclonecore \
    tests/core_checks.swift -o build/core-checks
  ./build/core-checks
  "$compiler" "${flags[@]}" -parse-as-library -I build -L build -lappclonecore \
    tests/application_link_checks.swift -o build/application-link-checks
  ./build/application-link-checks
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p '*_test.py' -v
fi
printf 'Built %s/build/app-clone (%s)\n' "$PWD" "$mode"
