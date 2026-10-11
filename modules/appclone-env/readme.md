# app-clone 环境模块

本项目的环境配置源码生成器、Mach-O 依赖插入器，以及 `libappclone_env.dylib` 的 C 初始化代码。Swift 部分已编入 CLI，由 `adv-clone` 命令调用。

## 命令行使用

先用 `clone` 创建分身，退出分身后执行：

```sh
./build/app-clone adv-clone ~/Applications/app-clone/wechat-work.app \
  --data-dir "$HOME/Library/Application Support/app-clone/data/wechat-work" \
  --proxy http://127.0.0.1:7890 \
  --locale zh_CN.UTF-8
```

三个选项可单独使用，未传入的配置会保留。`--data-dir` 创建 `home`、`tmp` 子目录并设置 HOME、TMPDIR；`--proxy` 设置 HTTP_PROXY、HTTPS_PROXY；`--locale` 设置 LANG、LC_ALL。`--lang` 仍表示 CLI 输出语言。

`adv-clone <分身.app>` 查看配置；`adv-clone <分身.app> --reset` 移除动态库及依赖并重新签名，保留数据目录。可加 `--json` 读取分身记录中的 `environment`，未启用时该字段省略。

设置时需要 Apple Command Line Tools 或 Xcode。CLI 使用本模块生成 C 源码并编译双架构动态库，在暂存副本中插入依赖、签名并验证，再通过事务安装。失败时保留原分身和清单。源码只放在临时任务目录中，任务结束后清理。不需要手动构建或注入动态库。

| 文件 | 用途 |
| --- | --- |
| [env_source.swift](env_source.swift) | `EnvironmentSource.generate()` 将环境变量字典转换为 C 源码。 |
| [macho.swift](macho.swift) | `MachOInjector.insertingDylib()` 检查头部空间，返回追加动态库依赖后的数据。 |
| [env.c](env.c) | 空初始化入口，用于独立构建动态库。 |

## 本项目命名

| 名称 | 含义 |
| --- | --- |
| `{{APP_CLONE_DATA_DIR}}` | C 源码生成时展开的数据目录占位符，由 `dataDirectory` 参数提供；本身不是运行时环境变量。 |
| `APP_CLONE_ORIGINAL_HOME` | 动态库加载时保存的原始 `HOME`，已有值时保留。 |
| `appclone_env_init()` | C 动态库加载时自动执行的初始化函数。 |
| `libappclone_env.dylib` | 动态库产物名称。 |

## 构建

在仓库根目录执行：

```sh
make env-dylib
```

生成 `build/libappclone_env.dylib`，包含 Apple Silicon 和 Intel 两个架构，最低系统版本为 macOS 14。构建使用 clang 编译 `env.c`，执行 Ad-hoc 签名并检查签名及架构。`build/` 已被 Git 忽略。

加载标识为 `@executable_path/../Frameworks/libappclone_env.dylib`，对应应用的 `Contents/Frameworks/libappclone_env.dylib`。

`env.c` 只保留空的 `appclone_env_init()` 入口，没有预设目录、代理或语言，加载时不设置或清除任何环境变量。`adv-clone` 根据用户传入的配置生成具体初始化代码。

## Swift 调用

```swift
let source = try EnvironmentSource.generate(
    variables: [
        "HOME": "{{APP_CLONE_DATA_DIR}}/home",
        "TMPDIR": "{{APP_CLONE_DATA_DIR}}/tmp",
        "HTTP_PROXY": "http://127.0.0.1:7890",
    ],
    dataDirectory: URL(fileURLWithPath: "/example/clone-data")
)

// source 是待编译的 C 源码；生成动作不会修改当前进程环境。
// executableData 是应用副本的可执行文件内容。
let patched = try MachOInjector.insertingDylib(
    "@executable_path/../Frameworks/libappclone_env.dylib",
    into: executableData
)
// patched 是内存中的副本，调用方负责写入和重新签名。
```

源码生成器验证变量名和 NUL，转义 C 字符串，并排序变量以保证输出稳定。Mach-O 插入器支持单架构 64 位文件和 FAT32/FAT64 通用文件中的 Apple Silicon、Intel 64 位切片，只使用已有的全零头部余量，不搬移节区。重复插入相同的普通依赖不会增加命令；同名的其他加载方式会报错。

`MachOInjector.removingDylib(_:from:)` 移除最后一个动态库依赖，原有依赖的序号保持不变。如果此后又加入了其他库，则拒绝移除。两种操作都返回内存副本，不直接修改文件。

动态库仅在加载时设置进程环境变量，不创建线程或轮询。应用是否使用新路径、代理和语言取决于其实现；钥匙串、硬编码路径及已缓存的目录不会因此自动隔离。初始化发生在应用 `main()` 之前，不保证早于其他动态库或 Objective-C 初始化代码。
