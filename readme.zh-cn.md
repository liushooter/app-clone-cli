# app-clone-cli

使用 Swift 编写的 macOS 应用分身命令行工具，支持简体中文和英文，无第三方运行依赖。

[English](readme.md)

## 构建

需要 macOS 14+、提供 Swift 6+ 的 Apple 开发工具链；运行测试还需要 Python 3。构建脚本支持 Apple Silicon 和 Intel，并为当前机器架构生成程序。

```sh
make release
./build/app-clone --version
./build/app-clone help --lang zh
```

生成的 `build/app-clone` 可独立运行，不依赖源码目录、外部翻译文件或单独的核心库。可将它复制到 `PATH` 中的目录。

`make`（或 `make build`）生成开发版本，`make test` 编译并测试，`make help` 查看可用目标。小写文件 `makefile` 会被 `make` 自动识别，内部调用 `build.sh` 完成编译。脚本通过 `xcrun` 获取同一开发工具链中的编译器和 SDK；需要自定义时，可用 `APP_CLONE_SWIFTC` 和 `APP_CLONE_SDK` 指定匹配的组合。

## 发布版本

推送 `v*` tag 后，GitHub Actions 会分别在 Apple Silicon 和 Intel 上运行完整测试、编译优化版本，再创建 GitHub Release，上传两个架构的 `.tar.gz` 包和 `sha256sums.txt`。压缩包包含可执行文件及中英文说明文档，要求 macOS 14+。

发布前将 `sources/core/version.swift` 中的版本号更新并提交，然后推送对应 tag。tag 去掉 `v` 后必须与 CLI 版本完全一致，否则发布失败。例如，版本号为 `0.2.0` 时：

```sh
git push origin main
git tag -a v0.2.0 -m "发布 v0.2.0"
git push origin v0.2.0
```

tag 支持 `v0.1.0` 或 `v0.2.0-rc.1` 这样的格式，后者会标记为预发布。工作流使用内置 `GITHUB_TOKEN`，无需额外配置发布密钥；两个架构均成功后才会发布。失败后可在 Actions 中重新运行，已发布版本应使用新版本号和新 tag。

按 Mac 的芯片类型选择压缩包，解压即可运行。以 `v0.2.0` 为例：

| Mac 芯片 | 下载文件 |
| --- | --- |
| Apple 芯片（M 系列） | `app-clone-v0.2.0-macos-apple-silicon.tar.gz` |
| Intel 处理器 | `app-clone-v0.2.0-macos-intel.tar.gz` |

可在苹果菜单 →「关于本机」中查看芯片或处理器类型。将校验文件与压缩包放在同一目录，可用 `shasum -a 256 --check --ignore-missing sha256sums.txt` 校验下载文件。

## 使用

```sh
./build/app-clone inspect /Applications/WeChat.app
./build/app-clone clone /Applications/WeChat.app --name 微信工作
./build/app-clone list
./build/app-clone icon ~/Applications/app-clone/微信工作.app ~/Pictures/work.png
./build/app-clone rename ~/Applications/app-clone/微信工作.app 微信2
./build/app-clone verify ~/Applications/app-clone/微信2.app
./build/app-clone stats
./build/app-clone remove ~/Applications/app-clone/微信2.app
```

| 命令 | 功能 |
| --- | --- |
| `clone <来源.app> --name <名称> [--icon <图片>]` | 创建分身，`create` 为同义命令 |
| `inspect <应用.app>` | 查看 Bundle ID、版本等元数据 |
| `list` | 列出分身名称和完整路径 |
| `icon <分身.app> <图片>` | 使用 PNG、JPEG 或 ICNS 替换图标 |
| `rename <分身.app> <名称>` | 修改显示名称、应用包文件名和已有软链接 |
| `adv-clone <分身.app> [--data-dir <目录>] [--proxy <地址>] [--locale <语言>] [--app-language <语言标识>]` | 查看或更新环境配置，`--reset` 移除配置 |
| `verify <分身.app>` | 检查归属、签名、自定义图标和环境动态库 |
| `remove <分身.app>` | 移除受管理的副本，保留应用用户数据 |
| `stats` | 按原应用显示累计成功创建数和现存分身数 |
| `register` | 创建应用软链接并向 macOS 注册 |
| `doctor` | 检查系统工具是否可用 |
| `version` / `--version` | 查看 CLI 版本 |
| `help` / `--help` | 查看帮助 |

分身路径可从 Finder 拖入终端，也支持软链接。换图标、改环境、改名和移除前需退出对应分身。换图标和改名保留当前应用版本、分身身份及环境配置；不提供应用更新命令。

## 高级环境配置

先用 `clone` 创建分身，再配置这个已有副本：

```sh
./build/app-clone adv-clone --lang zh
./build/app-clone adv-clone ~/Applications/app-clone/微信工作.app \
  --data-dir "$HOME/Library/Application Support/app-clone/data/wechat-work" \
  --proxy http://127.0.0.1:7890 \
  --locale zh_CN.UTF-8

# 查看配置，或移除配置并保留用户数据。
./build/app-clone adv-clone ~/Applications/app-clone/微信工作.app
./build/app-clone adv-clone ~/Applications/app-clone/微信工作.app --reset
```

各选项可单独使用，只修改传入的项，保留其他配置。`--data-dir` 创建 `home`、`tmp` 子目录并设置分身的 HOME、TMPDIR；`--proxy` 设置 HTTP_PROXY、HTTPS_PROXY，仅支持 HTTP/HTTPS 地址；`--locale` 设置 LANG、LC_ALL，而 `--lang` 控制 CLI 输出语言。加 `--json` 返回分身记录，启用后包含 `environment` 字段。

使用独立的 `--app-language` 为不同分身指定界面语言，可与 `--locale` 分开设置：

```sh
./build/app-clone adv-clone ~/Applications/app-clone/微信工作.app --app-language zh-CN
./build/app-clone adv-clone ~/Applications/app-clone/微信个人.app --app-language en
```

动态库在每次启动时将 `AppleLanguages` 写入进程的临时参数域，不写入应用或系统的持久偏好。配置保存在 `environment.appLanguage`，下次启动继续生效，直到修改或 `--reset`。显式启动参数（如 `open -a <分身.app> --args -AppleLanguages '(ja)'`）优先。应用需自带对应翻译并遵循 macOS 语言偏好；初始化在 `main()` 前执行，其他动态库或 Objective-C 初始化代码提前缓存的语言不保证改变。

设置时需要 Apple Command Line Tools 或 Xcode。命令按配置生成并编译双架构 `libappclone_env.dylib`，在暂存副本中添加主程序依赖、签名和验证，再通过事务安装。准备失败保留原分身和清单，不需要手动执行 `make env-dylib` 或注入动态库。

配置在下次启动生效，不自动迁移用户数据；`--reset` 和 `remove` 都保留数据目录。应用是否采用这些环境变量取决于其实现，钥匙串、硬编码路径及所有辅助进程并不因此自动隔离。不支持的格式、加密或头部余量不足会被拒绝。重置要求本模块仍为最后一个动态库依赖，以保留其他库的序号。

## 工作空间

默认工作空间为 `~/Library/Application Support/app-clone`，包含：

- `apps/`：分身应用。
- `state.json`：分身清单和创建统计。
- `staging/`：操作期间的暂存副本。
- `data/`：可选的高级配置数据目录，通过 `--data-dir` 指定。
- `pending.json`：事务进行中的恢复记录。

`~/Applications/app-clone/` 只存放指向副本的软链接，不搬运应用包。Finder、Spotlight 和启动台的实际显示由 macOS 控制，同名的无关文件和其他链接不会被覆盖。

`--workspace <目录>` 指定独立工作空间。clone、list、stats、register 默认使用上述目录；icon、rename、adv-clone、verify、remove 根据分身路径自动定位工作空间，也允许显式指定匹配的工作空间。自定义工作空间默认不创建应用入口，需要时运行 `register --workspace <目录>`。

不自动迁移此前存放在其他位置的应用。新分身 Bundle ID 为 `<原应用BundleID>.<创建序号>.<uuid>`，成功创建后递增，删除不复用。兼容读取旧版清单；历史不完整时通过 `historyComplete: false` 标识。

## 语言与脚本调用

```sh
./build/app-clone help --lang zh
./build/app-clone --lang en list --json
```

语言优先级：`--lang zh|en` → 非空 `LC_ALL` → `LC_MESSAGES` → `LANG` → macOS 首选语言。中文区域使用简体中文，其他语言和 `C` / `POSIX` 回退英文。`--lang` 可放在命令前后，`--` 之后按普通参数处理。

`doctor` 默认逐行显示工具状态和路径；脚本调用时使用 `doctor --json` 获取结构化检查结果。

结构化成功结果写入 stdout，进度和错误写入 stderr。`--json` 关闭进度提示，并将错误输出为 `{"code": "...", "message": "..."}`。JSON 字段、错误码和阶段名固定；错误文案随语言变化，应用元数据和系统工具诊断保持原文。退出码为成功 `0`、失败 `1`、取消 `130`。脚本应检查退出码和 `code`，不要匹配翻译后的文案。

## 实现与边界

核心流程为：复制到暂存目录 → 设置分身身份和名称 → 处理可选图标 → 清理扩展属性 → Ad-hoc 签名 → 验证 → 提交副本和清单。文件锁串行处理同一工作空间中的操作，事务日志用于中断恢复。准备失败会清理暂存文件并保留已有副本，原应用不参与修改。

`clone` / `create` 不支持克隆系统应用（例如 Maps、Finder、Safari）。创建前解析符号链接，检查真实路径是否位于 `/System` 或 `/Library/Apple/System`，以及应用目录或主程序是否带有 `restricted` 系统保护标记；命中时提示“不支持克隆系统应用”，JSON 错误码为 `unsupported_system_app`。拦截发生在创建工作空间和复制文件之前。`inspect` 仍可查看系统应用信息。仅有 `com.apple.*` Bundle ID 不会触发拦截。

分身会改变应用身份和签名，部分应用可能无法启动，也可能通过自身的存储规则共享数据。独立登录和数据隔离取决于应用自身行为；本工具不迁移账号或应用数据。没有常驻服务和空闲轮询。

## 开发

```sh
make test
```

包含 50 项 CLI 集成测试，以及 Swift 进程、国际化、链接和环境模块检查。测试使用临时目录中的双架构应用验证实际环境注入、更新、重置和失败保护，并验证系统应用及其软链接入口的克隆拦截。macOS CI 执行测试和发布构建检查。

- `sources/cli/`：命令参数、中英帮助和输出。
- `sources/core/`：分身操作、事务、签名、图标和国际化。
- `modules/appclone-env/`：`adv-clone` 使用的 C 源码生成器和 Mach-O 辅助代码。
- `tests/`：集成测试和 Swift 检查。

`make env-dylib` 构建只保留空初始化入口的 `build/libappclone_env.dylib`，加载时不修改环境变量。`adv-clone` 根据实际选项另行生成动态库。接口和命名见[环境模块说明](modules/appclone-env/readme.md)。

源文件名使用小写；Swift 用 `swift-format` 格式化，Python 用 `ruff format` 格式化。提交前运行完整测试，不提交构建产物、工作空间数据、密钥和本地配置。
