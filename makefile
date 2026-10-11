.DEFAULT_GOAL := build
.PHONY: build release test env-dylib help

# All build modes share the same output directory.
.NOTPARALLEL:

build release test env-dylib:
	@./build.sh $@

help:
	@printf '%s\n' \
	  'Usage: make [build|release|test|env-dylib|help]' \
	  '  build    Compile a development binary (default).' \
	  '  release  Compile an optimized binary.' \
	  '  test     Compile and run Swift checks and CLI integration tests.' \
	  '  env-dylib Compile libappclone_env.dylib for Apple Silicon and Intel.' \
	  'CLI output: build/app-clone' \
	  'Environment dylib output: build/libappclone_env.dylib'
