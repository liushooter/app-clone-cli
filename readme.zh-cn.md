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
| `verify <分身.app>` | 检查归属、签名和自定义图标 |
| `remove <分身.app>` | 移除受管理的副本，保留应用用户数据 |
| `stats` | 按原应用显示累计成功创建数和现存分身数 |
| `register` | 创建应用软链接并向 macOS 注册 |
| `doctor` | 检查系统工具是否可用 |
| `version` / `--version` | 查看 CLI 版本 |
| `help` / `--help` | 查看帮助 |

分身路径可从 Finder 拖入终端，也支持软链接。换图标、改名和移除前需退出对应分身。换图标和改名保留当前应用版本与分身身份；不提供应用更新命令。

## 工作空间

默认工作空间为 `~/Library/Application Support/app-clone`，包含：

- `apps/`：分身应用。
- `state.json`：分身清单和创建统计。
- `staging/`：操作期间的暂存副本。
- `pending.json`：事务进行中的恢复记录。

`~/Applications/app-clone/` 只存放指向副本的软链接，不搬运应用包。Finder、Spotlight 和启动台的实际显示由 macOS 控制，同名的无关文件和其他链接不会被覆盖。

`--workspace <目录>` 指定独立工作空间。clone、list、stats、register 默认使用上述目录；icon、rename、verify、remove 根据分身路径自动定位工作空间，也允许显式指定匹配的工作空间。自定义工作空间默认不创建应用入口，需要时运行 `register --workspace <目录>`。

不自动迁移此前存放在其他位置的应用。新分身 Bundle ID 为 `<原应用BundleID>.<创建序号>.<uuid>`，成功创建后递增，删除不复用。兼容读取旧版清单；历史不完整时通过 `historyComplete: false` 标识。

## 语言与脚本调用

```sh
./build/app-clone help --lang zh
./build/app-clone --lang en list --json
```

语言优先级：`--lang zh|en` → 非空 `LC_ALL` → `LC_MESSAGES` → `LANG` → macOS 首选语言。中文区域使用简体中文，其他语言和 `C` / `POSIX` 回退英文。`--lang` 可放在命令前后，`--` 之后按普通参数处理。

结构化成功结果写入 stdout，进度和错误写入 stderr。`--json` 关闭进度提示，并将错误输出为 `{"code": "...", "message": "..."}`。JSON 字段、错误码和阶段名固定；错误文案随语言变化，应用元数据和系统工具诊断保持原文。退出码为成功 `0`、失败 `1`、取消 `130`。脚本应检查退出码和 `code`，不要匹配翻译后的文案。

## 实现与边界

核心流程为：复制到暂存目录 → 设置分身身份和名称 → 处理可选图标 → 清理扩展属性 → Ad-hoc 签名 → 验证 → 提交副本和清单。文件锁串行处理同一工作空间中的操作，事务日志用于中断恢复。准备失败会清理暂存文件并保留已有副本，原应用不参与修改。

分身会改变应用身份和签名，部分应用可能无法启动，也可能通过自身的存储规则共享数据。独立登录和数据隔离取决于应用自身行为；本工具不迁移账号或应用数据。没有常驻服务和空闲轮询。

## 开发

```sh
make test
```

包含 40 项 CLI 集成测试，以及 Swift 进程、国际化和链接检查。测试使用临时目录中的应用夹具并自动清理。macOS CI 执行测试和发布构建检查。

- `sources/cli/`：命令参数、中英帮助和输出。
- `sources/core/`：分身操作、事务、签名、图标和国际化。
- `tests/`：集成测试和 Swift 检查。

源文件名使用小写；Swift 用 `swift-format` 格式化，Python 用 `ruff format` 格式化。提交前运行完整测试，不提交构建产物、工作空间数据、密钥和本地配置。

## 许可证

开源许可证尚未确定。
