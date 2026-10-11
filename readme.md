# app-clone-cli

A macOS command-line tool for creating and managing independent app copies. Written in Swift, with English and Simplified Chinese output and no third-party runtime dependencies.

[简体中文](readme.zh-cn.md)

## Build

Requires macOS 14 or later and an Apple developer toolchain with Swift 6 or later. Tests also require Python 3. Both Apple Silicon and Intel targets are supported by the build script; it builds for the current machine.

```sh
make release
./build/app-clone --version
./build/app-clone help --lang en
```

The executable is `build/app-clone`. It works outside the source directory and does not require translation files or a separate core library. Add its directory to your `PATH`, or copy the executable to a directory already on your `PATH`.

`make` (or `make build`) builds a development binary. `make test` compiles and runs tests; `make help` lists the available targets. The lowercase `makefile` is discovered automatically by `make` and delegates compilation to `build.sh`. Compiler and SDK are resolved together using `xcrun`; advanced builds may set `APP_CLONE_SWIFTC` and `APP_CLONE_SDK` to a matching pair. No machine-specific paths are configured in the repository.

## Releases

Pushing a `v*` tag triggers GitHub Actions to run the full suite and build optimized binaries on both Apple Silicon and Intel. Once both builds succeed, it creates a GitHub Release with two `.tar.gz` archives and `sha256sums.txt`. Each archive contains the executable and both readme files and requires macOS 14 or later.

Update and commit the version in `sources/core/version.swift` before pushing the corresponding tag. The tag without its `v` prefix must exactly match the CLI version, or the release fails. For version `0.1.0`:

```sh
git push origin main
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

Tags may look like `v0.1.0` or `v0.2.0-rc.1`; the latter produces a prerelease. Publishing uses the built-in `GITHUB_TOKEN`, with no additional release secret required. Failed runs can be rerun in Actions; use a new version and tag for changes to an already published release.

Choose the archive for your Mac's chip, then extract it to run the tool. For version `v0.1.0`:

| Mac chip | Download |
| --- | --- |
| Apple Silicon (M series) | `app-clone-v0.1.0-macos-apple-silicon.tar.gz` |
| Intel processor | `app-clone-v0.1.0-macos-intel.tar.gz` |

You can find your chip or processor in the Apple menu → About This Mac. Place the archive beside the checksum file and run `shasum -a 256 --check --ignore-missing sha256sums.txt` to verify the downloaded archive.

## Usage

```sh
# Inspect the original app, then create a named copy.
./build/app-clone inspect /Applications/WeChat.app
./build/app-clone clone /Applications/WeChat.app --name wechat-work

# List full paths, then manage a clone by its path (Finder drag-and-drop works).
./build/app-clone list
./build/app-clone icon ~/Applications/app-clone/wechat-work.app ~/Pictures/work.png
./build/app-clone rename ~/Applications/app-clone/wechat-work.app wechat-personal
./build/app-clone verify ~/Applications/app-clone/wechat-personal.app
./build/app-clone stats
./build/app-clone remove ~/Applications/app-clone/wechat-personal.app
```

| Command | Purpose |
| --- | --- |
| `clone <source.app> --name <name> [--icon <image>]` | Create a clone; `create` is an alias |
| `inspect <app>` | Read bundle metadata |
| `list` | List managed clones and their full paths |
| `icon <clone.app> <image>` | Replace the icon using PNG, JPEG, or ICNS |
| `rename <clone.app> <name>` | Change the display name, bundle filename, and existing shortcut |
| `verify <clone.app>` | Check ownership, signature, and any custom icon |
| `remove <clone.app>` | Remove the managed copy, preserving app user data |
| `stats` | Show total creations and current clone counts per source app |
| `register` | Create application symlinks and register them with macOS |
| `doctor` | Check required system tools |
| `version` / `--version` | Print the CLI version |
| `help` / `--help` | Show usage |

Quit a clone before changing its icon, renaming it, or removing it. Rename and icon replacement preserve the installed app version and clone identity. There is no app update command.

## Workspaces and storage

The default workspace is `~/Library/Application Support/app-clone`:

```text
apps/         Managed .app copies
state.json    Clone catalog and creation counts
staging/      Temporary copies during operations
pending.json  Recovery journal, present only during a transaction
```

`~/Applications/app-clone/` contains symlinks to the copies. App bundles stay in the workspace. macOS controls their appearance in Finder, Spotlight, and Launchpad. Existing unrelated files and shortcuts are never overwritten.

`--workspace <directory>` selects a separate workspace. `clone`, `list`, `stats`, and `register` otherwise use the default workspace. `icon`, `rename`, `verify`, and `remove` locate the workspace from the clone path, including symlinks. An explicit workspace must match the managed clone.

Custom workspaces do not automatically publish application shortcuts. Run `register --workspace <directory>` to create them. Existing applications in other locations are not automatically moved or migrated.

New Bundle IDs use `<source-bundle-id>.<creation-number>.<uuid>`. Numbers increase per source app in each workspace after successful creation and are not reused after removal. Legacy catalogs remain readable; incomplete historical counts are identified by `historyComplete: false`.

## Language and scripting

```sh
./build/app-clone help --lang zh
./build/app-clone --lang en list --json
```

Language priority: `--lang zh|en`, then nonempty `LC_ALL`, `LC_MESSAGES`, `LANG`, then the macOS preferred language. Chinese locales use Simplified Chinese; unsupported languages and `C` / `POSIX` use English. `--lang` may precede or follow the command; `--` ends option parsing.

`doctor` shows each tool's status and path as text by default. Use `doctor --json` for structured check results in scripts.

Successful structured results go to stdout; progress and errors go to stderr. `--json` suppresses progress and formats errors as `{"code": "...", "message": "..."}`. JSON keys, error codes, and stage identifiers stay stable across languages. Human-readable error messages are localized; application metadata and external tool diagnostics retain their original text.

Exit status: `0` for success, `1` for failure, `130` for cancellation. For scripts, check the exit status and `code`, not translated messages.

## How it works

The core copies the source into staging, assigns the clone identity and name, applies an optional icon, clears extended attributes, signs the copy ad hoc, verifies it, and commits the app and catalog together. A workspace lock serializes operations; a journal enables recovery after interruption. Preparation failures clean up temporary files and preserve existing clones. The original app is not modified.

Cloning changes the app's identity and signature. Some apps may refuse to run or may still share data through their own storage conventions. Separate login sessions and data isolation depend on the app. This tool does not migrate accounts or app data. It runs only while a command is active, with no background service or idle polling.

## Development

```sh
make test
```

The suite includes 40 CLI integration tests plus Swift process, localization, and symlink checks. Fixtures are created in temporary directories, including small signed apps, and cleaned up afterwards. GitHub Actions builds and tests on macOS and checks the release binary.

```text
sources/cli/   Argument parsing, bilingual help, text and JSON output
sources/core/  Clone operations, transactions, signing, icons, localization
tests/        Integration tests and Swift checks
```

Keep source filenames lowercase. Format Swift with `swift-format` and Python with `ruff format`; run the full suite before submitting a change. Generated binaries, workspace data, local configuration, and credentials do not belong in Git.

## License

No open-source license has been selected yet.
