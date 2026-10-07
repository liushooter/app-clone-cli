.DEFAULT_GOAL := build
.PHONY: build release test help

# All build modes share the same output directory.
.NOTPARALLEL:

build release test:
	@./build.sh $@

help:
	@printf '%s\n' \
	  'Usage: make [build|release|test|help]' \
	  '  build    Compile a development binary (default).' \
	  '  release  Compile an optimized binary.' \
	  '  test     Compile and run Swift checks and CLI integration tests.' \
	  'Output: build/app-clone'
