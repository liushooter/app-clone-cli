# 克隆前置检查

前置检查统一处理应用准入与资源要求。Electron 仅用于拒绝克隆，不包含名称兼容、运行时修补或其他克隆支持。

`sources/core/clone_policy.swift` 是代码开关、禁止克隆列表与阈值的唯一默认配置。修改后重新编译，创建及重建统一生效，不提供命令行跳过选项。

| 检查 | 默认规则 | JSON 错误码 |
| --- | --- | --- |
| 禁止克隆列表 | 完整 Bundle ID 忽略大小写匹配 `ru.keepcoder.Telegram` | `blocked_application` |
| iOS 平台 | 拒绝 iPhone、iPad 与 iOS 模拟器应用 | `unsupported_ios_app` |
| 系统应用 | 拒绝系统路径或带 `restricted` 标记的应用 | `unsupported_system_app` |
| Electron 框架 | 拒绝标准框架和包含有效 Electron fuse wire 的改名框架 | `unsupported_electron_app` |
| 应用大小 | 拒绝估算大小超过 5 GB（5,000,000,000 字节）的应用 | `application_too_large` |
| 可用磁盘 | 应用目录至少需要应用大小 × 2 + 1 GB，工作空间目录至少需要 1 GB | `insufficient_disk_space` |

`ClonePolicy.isEnabled` 是总开关，六项检查各有独立的 `checks…` 开关，默认全部开启。关闭大小检查时，磁盘检查仍完整统计大小；大小与磁盘检查都关闭时不做体积遍历。关闭策略不会绕过基本包结构、路径边界、符号链接、归属、运行状态、签名、取消或事务校验，也不会增加应用兼容能力。

`ClonePreflight.inspectSource()` 按以下顺序执行：基本路径检查 → 禁止克隆列表 → iOS 平台 → 完整 macOS 包结构 → 系统保护 → Electron → 应用大小。创建时每次重新检查，通过后才初始化工作空间。改名、换图标和修改环境配置时检查当前分身，并先用清单中的原应用 ID 核对禁止列表，再核对当前包 ID，避免生成的新 ID 绕过规则。列表命中后不会继续解析主程序、统计体积或复制。

`build()` 接收这次检查结果，在工作空间锁内执行 `checkDestination()`，通过后才建立暂存任务和复制。容量不足时可能已经初始化空工作空间，但不会创建复制任务、更新清单或消耗创建序号。重建拒绝后原分身、配置和清单保持不变。

`inspect` 继续只读取基本 macOS 应用元数据，不表示应用可以克隆；`list`、`stats`、`verify`、只读 `env`、定位、注册和删除不执行准入策略。无需重建的同名改名或无配置重置保留原有行为。

## 检测实现

- `AppPlatformInspector` 与 `MachOPlatforms` 读取标准包、平铺 iOS 包和 `Wrapper`／`WrappedBundle` 包装的元数据，以及各架构的 Mach-O 头部和 load commands。实际构建平台优先于 plist，避免误拦带有 iOS 元数据的 Catalyst 应用。
- `ElectronInspector` 只读取应用直属 Framework 的运行时，支持版本链接及不同于目录名的可执行文件名。标准框架兼容旧版无 fuse 的运行时；改名框架验证 fuse wire 的版本、长度与开关值，分块读取、覆盖跨块标记并支持取消。不启动应用，不修改 fuse 或 ASAR。
- `StorageInspector` 遍历隐藏文件、嵌套应用和框架，只读取大小元数据。文件逻辑大小与已分配空间取较大值，稀疏或压缩文件按复制后可能占用的空间保守估算；符号链接不重复遍历目标。超过上限提前结束，无法完整读取时报 `application_size_unavailable`。
- 磁盘检查使用当前可用容量，不计入可能清理的缓存或 APFS 共享块。目录尚不存在时查询最近的已存在父目录；容量无法读取时报 `disk_capacity_unavailable`。预检不预留空间，之后写入失败仍由原有事务清理与恢复处理。

`./build.sh test` 使用临时应用和隔离工作空间验证策略开关、列表匹配、iOS 包装与 Mach-O、Electron 改名框架及跨块检测、大小限制、容量边界、取消和重建失败保护；没有实际克隆或启动 Electron 应用。
