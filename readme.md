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

Update and commit the version in `sources/core/version.swift` before pushing the corresponding tag. The tag without its `v` prefix must exactly match the CLI version, or the release fails. For version `0.2.0`:

```sh
git push origin main
git tag -a v0.2.0 -m "Release v0.2.0"
git push origin v0.2.0
```

Tags may look like `v0.1.0` or `v0.2.0-rc.1`; the latter produces a prerelease. Publishing uses the built-in `GITHUB_TOKEN`, with no additional release secret required. Failed runs can be rerun in Actions; use a new version and tag for changes to an already published release.

Choose the archive for your Mac's chip, then extract it to run the tool. For version `v0.2.0`:

| Mac chip | Download |
| --- | --- |
| Apple Silicon (M series) | `app-clone-v0.2.0-macos-apple-silicon.tar.gz` |
| Intel processor | `app-clone-v0.2.0-macos-intel.tar.gz` |

You can find your chip or processor in the Apple menu → About This Mac. Place the archive beside the checksum file and run `shasum -a 256 --check --ignore-missing sha256sums.txt` to verify the downloaded archive.

## Usage

```sh
# Inspect the original app, then create a named copy.
./build/app-clone inspect /Applications/WeChat.app
./build/app-clone clone /Applications/WeChat.app --name wechat-work

# List full paths, then manage a clone by its path (Finder drag-and-drop works).
./build/app-clone list
./build/app-clone open
./build/app-clone open ~/Applications/app-clone/wechat-work.app
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
| `open [clone.app]` | Open the clones directory in Finder, or reveal a specific clone's actual bundle |
| `icon <clone.app> <image>` | Replace the icon using PNG, JPEG, or ICNS |
| `rename <clone.app> <name>` | Change the display name, bundle filename, and existing shortcut |
| `adv-clone <clone.app> [--data-dir <dir>] [--proxy <url>] [--locale <locale>] [--app-language <tag>]` | View or update a managed clone's environment; `--reset` removes the configuration |
| `verify <clone.app>` | Check ownership, signature, custom icon, and environment library |
| `remove <clone.app>` | Remove the managed copy, preserving app user data |
| `stats` | Show total creations and current clone counts per source app |
| `register` | Create application symlinks and register them with macOS |
| `doctor` | Check required system tools |
| `version` / `--version` | Print the CLI version |
| `help` / `--help` | Show usage |

Quit a clone before changing its icon, environment, or name, or removing it. Rename and icon replacement preserve the installed app version, clone identity, and environment configuration. There is no app update command.

`open` without a path opens the workspace's `apps` directory, creating it if necessary. With a clone path or symlink, it selects the actual app bundle in Finder without launching the app. `--workspace` selects a custom workspace; `--json` still opens Finder and returns `{"path": "<actual location>"}`.

## Advanced environment settings

Create a clone with `clone` first, then configure that managed copy:

```sh
./build/app-clone adv-clone --lang en
./build/app-clone adv-clone ~/Applications/app-clone/wechat-work.app \
  --data-dir "$HOME/Library/Application Support/app-clone/data/wechat-work" \
  --proxy http://127.0.0.1:7890 \
  --locale zh_CN.UTF-8

# Read the current settings, or remove them while keeping user data.
./build/app-clone adv-clone ~/Applications/app-clone/wechat-work.app
./build/app-clone adv-clone ~/Applications/app-clone/wechat-work.app --reset
```

Options can be used separately; omitted settings are preserved. `--data-dir` creates `home` and `tmp` subdirectories and sets `HOME` and `TMPDIR`. `--proxy` sets `HTTP_PROXY` and `HTTPS_PROXY`; only HTTP/HTTPS proxy URLs are supported. `--locale` sets `LANG` and `LC_ALL`, while `--lang` controls the CLI's own output. `--json` returns the clone record, including `environment` when enabled.

Use `--app-language` to give each clone its own interface language, independently of `--locale`:

```sh
./build/app-clone adv-clone ~/Applications/app-clone/wechat-work.app --app-language zh-CN
./build/app-clone adv-clone ~/Applications/app-clone/wechat-personal.app --app-language en
```

The library sets `AppleLanguages` in the process's temporary argument domain at launch, without writing app or system preferences. The setting is stored as `environment.appLanguage` and reapplied each launch until changed or reset. Explicit launch arguments such as `open -a <clone.app> --args -AppleLanguages '(ja)'` take priority. The app must include the requested translation and honor macOS language preferences. Initialization runs before `main()`; code in other libraries or Objective-C initializers may have already cached a language.

Setting configuration requires Apple Command Line Tools or Xcode. The command generates and compiles a universal `libappclone_env.dylib` for that configuration, adds a dependency to the main executable, and signs and verifies the staged copy before installing it. It uses the existing transaction recovery flow; failures preserve the installed clone and catalog. There is no need to run `make env-dylib` or inject the library yourself.

Settings apply on the next launch. User data is not migrated or deleted, including after `--reset` or `remove`. Applications decide whether to honor these environment variables; this does not isolate keychain entries, hard-coded paths, or every helper process. Unsupported, encrypted, or insufficiently padded executables are rejected. Reset removes the module's dependency only when it remains the last library dependency, preserving existing library ordinals.

## Workspaces and storage

The default workspace is `~/Library/Application Support/app-clone`:

```text
apps/         Managed .app copies
state.json    Clone catalog and creation counts
staging/      Temporary copies during operations
data/         Optional advanced data directories (when selected with --data-dir)
pending.json  Recovery journal, present only during a transaction
```

`~/Applications/app-clone/` contains symlinks to the copies. App bundles stay in the workspace. macOS controls their appearance in Finder, Spotlight, and Launchpad. Existing unrelated files and shortcuts are never overwritten.

`--workspace <directory>` selects a separate workspace. `clone`, `list`, `stats`, `register`, and `open` without a path otherwise use the default workspace. `icon`, `rename`, `adv-clone`, `verify`, `remove`, and `open` with a clone path locate the workspace from that path, including symlinks. An explicit workspace must match the managed clone.

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

`clone` / `create` do not support system apps such as Maps, Finder, and Safari. Before creating a workspace or copying files, the tool resolves symlinks and rejects apps whose real path is under `/System` or `/Library/Apple/System`, or whose bundle directory or main executable carries the `restricted` system-protection flag. The error is "Cloning system apps is not supported", with JSON code `unsupported_system_app`. `inspect` can still read system app metadata. A `com.apple.*` Bundle ID alone does not trigger rejection.

Cloning changes the app's identity and signature. Some apps may refuse to run or may still share data through their own storage conventions. Separate login sessions and data isolation depend on the app. This tool does not migrate accounts or app data. It runs only while a command is active, with no background service or idle polling.

## Development

```sh
make test
```

The suite includes 51 CLI integration tests plus Swift process, localization, location, symlink, and environment module checks. Fixtures include a signed universal app used to test injected environment variables, updates, reset, and failure preservation. Tests also cover rejection of system apps and their symlink entries. GitHub Actions builds and tests on macOS and checks the release binary.

```text
sources/cli/          Argument parsing, bilingual help, text and JSON output
sources/core/         Clone operations, transactions, signing, icons, localization
modules/appclone-env/  C source generator and Mach-O helpers used by adv-clone
tests/                Integration tests and Swift checks
```

`make env-dylib` builds `build/libappclone_env.dylib` with an empty initializer that leaves environment variables unchanged. The `adv-clone` command generates a separate library from the selected settings. See the [environment module guide](modules/appclone-env/readme.md) for its API and naming.

Keep source filenames lowercase. Format Swift with `swift-format` and Python with `ruff format`; run the full suite before submitting a change. Generated binaries, workspace data, local configuration, and credentials do not belong in Git.
