/// 前置检查的唯一默认配置。修改此处并重新编译，创建和重建会统一采用。
struct ClonePolicy: Sendable {
  static let current = ClonePolicy()

  // 总开关；关闭后跳过以下六项策略，基本包结构与事务校验仍由核心负责。
  var isEnabled = true

  var checksBlockedApplications = true
  var checksIOSApplications = true
  var checksSystemApplications = true
  var checksElectronApplications = true
  var checksApplicationSize = true
  var checksDiskSpace = true

  // 按完整 Bundle ID 匹配，忽略大小写；增删条目后重新编译即可生效。
  var blockedBundleIdentifiers: Set<String> = [
    "ru.keepcoder.Telegram"
  ]

  var maximumApplicationBytes: Int64 = 5_000_000_000
  var copySpaceMultiplier: Int64 = 2
  var reservedDiskBytes: Int64 = 1_000_000_000
}
