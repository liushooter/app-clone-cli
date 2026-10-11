#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mode="${1:-build}"
if [[ $# -gt 1 ]]; then
  printf '%s\n' 'Usage: ./build.sh [build|release|test|env-dylib|help]' >&2
  exit 2
fi
case "$mode" in
  build|release|test|env-dylib) ;;
  help|--help|-h)
    printf '%s\n' 'Usage: ./build.sh [build|release|test|env-dylib|help]' \
      '  build    Compile a development binary (default).' \
      '  release  Compile an optimized binary.' \
      '  test     Compile and run Swift checks and CLI integration tests.' \
      '  env-dylib Compile libappclone_env.dylib for Apple Silicon and Intel.' \
      'CLI output: build/app-clone' \
      'Environment dylib output: build/libappclone_env.dylib'
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
sdk="${APP_CLONE_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"

# This opt-in module build uses the fixed example configuration in env.c.
# It is not injected into the CLI or included in release archives.
if [[ "$mode" == env-dylib ]]; then
  env_compiler="$(xcrun --find clang)"
  mkdir -p build
  "$env_compiler" -isysroot "$sdk" -mmacosx-version-min=14.0 \
    -arch arm64 -arch x86_64 -dynamiclib -O2 -Wall -Wextra -Werror \
    -install_name '@executable_path/../Frameworks/libappclone_env.dylib' \
    modules/appclone-env/env.c -o build/libappclone_env.dylib
  /usr/bin/codesign --force --sign - build/libappclone_env.dylib
  /usr/bin/codesign --verify --strict build/libappclone_env.dylib
  xcrun lipo build/libappclone_env.dylib -verify_arch arm64 x86_64
  printf 'Built %s/build/libappclone_env.dylib (example configuration)\n' "$PWD"
  exit 0
fi

compiler="${APP_CLONE_SWIFTC:-$(xcrun --find swiftc)}"
arch="$(uname -m)"
mkdir -p build/module-cache
flags=(-sdk "$sdk" -target "${arch}-apple-macosx14.0" -swift-version 6
  -module-cache-path "$PWD/build/module-cache" -warnings-as-errors)
if [[ "$mode" == release ]]; then flags+=(-O); fi
if [[ "$mode" == test ]]; then flags+=(-enable-testing); fi

"$compiler" "${flags[@]}" -parse-as-library -emit-library -static -emit-module \
  -module-name appclonecore -emit-module-path build/appclonecore.swiftmodule \
  sources/core/*.swift modules/appclone-env/*.swift -o build/libappclonecore.a
"$compiler" "${flags[@]}" -parse-as-library -I build -L build -lappclonecore \
  sources/cli/*.swift -o build/app-clone

if [[ "$mode" == test ]]; then
  "$compiler" "${flags[@]}" -parse-as-library -I build -L build -lappclonecore \
    tests/core_checks.swift -o build/core-checks
  ./build/core-checks
  "$compiler" "${flags[@]}" -parse-as-library -I build -L build -lappclonecore \
    tests/application_link_checks.swift -o build/application-link-checks
  ./build/application-link-checks
  "$compiler" "${flags[@]}" -parse-as-library -I build -L build -lappclonecore \
    tests/environment_checks.swift -o build/environment-checks
  ./build/environment-checks
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p '*_test.py' -v
fi
printf 'Built %s/build/app-clone (%s)\n' "$PWD" "$mode"
