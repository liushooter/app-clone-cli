import Darwin
import Foundation

/// 只读取文件大小与卷容量；限制与是否允许继续由 ClonePreflight 决定。
struct StorageInspector: Sendable {
  private let capacity: @Sendable (URL) throws -> Int64

  init(capacity: @escaping @Sendable (URL) throws -> Int64 = Self.readAvailableCapacity) {
    self.capacity = capacity
  }

  /// 超过 stoppingAfter 时提前返回已累计的字节数，供调用方拒绝；未传上限则完整统计。
  static func applicationSize(
    at app: URL, stoppingAfter limit: Int64? = nil, token: CancellationToken = CancellationToken()
  ) throws -> Int64 {
    try token.check()
    do {
      try BundleFiles.requireRegular(app, directory: true)
      var enumerationError: (any Error)?
      let keys: Set<URLResourceKey> = [.totalFileSizeKey, .totalFileAllocatedSizeKey]
      guard
        let iterator = FileManager.default.enumerator(
          at: app, includingPropertiesForKeys: Array(keys), options: [],
          errorHandler: { _, error in
            enumerationError = error
            return false
          })
      else { throw unreadableApplication(app) }
      var total: Int64 = 0
      for case let entry as URL in iterator {
        try token.check()
        var information = stat()
        guard lstat(entry.path, &information) == 0 else { throw unreadableApplication(app) }
        let kind = information.st_mode & S_IFMT
        let size: Int64
        switch kind {
        case S_IFREG:
          let values = try entry.resourceValues(forKeys: keys)
          guard let logical = values.totalFileSize, logical >= 0,
            let allocated = values.totalFileAllocatedSize, allocated >= 0
          else { throw unreadableApplication(app) }
          // 压缩和稀疏文件复制后可能膨胀；硬链接也按独立文件保守估算。
          size = Int64(max(logical, allocated))
        case S_IFDIR, S_IFLNK:
          // 不跟随符号链接，Framework 的版本别名不会重复遍历目标。
          if kind == S_IFLNK { iterator.skipDescendants() }
          guard information.st_size >= 0, information.st_blocks >= 0,
            information.st_blocks <= Int64.max / 512
          else { throw unreadableApplication(app) }
          size = max(information.st_size, information.st_blocks * 512)
        default:
          throw unreadableApplication(app)
        }
        let (sum, overflow) = total.addingReportingOverflow(size)
        guard !overflow else { throw unreadableApplication(app) }
        total = sum
        if let limit, total > limit { return total }
      }
      try token.check()
      if enumerationError != nil { throw unreadableApplication(app) }
      return total
    } catch let failure as CloneFailure {
      throw failure
    } catch {
      throw unreadableApplication(app)
    }
  }

  func availableCapacity(at directory: URL) throws -> Int64 {
    do {
      let available = try capacity(directory)
      guard available >= 0 else { throw Self.unreadableCapacity(directory) }
      return available
    } catch let failure as CloneFailure {
      throw failure
    } catch {
      throw Self.unreadableCapacity(directory)
    }
  }

  private static func readAvailableCapacity(at directory: URL) throws -> Int64 {
    // 目录尚未创建时查询最近的已存在父目录，保留外置盘和单独挂载卷的归属。
    var existing = BundleFiles.canonical(directory)
    while true {
      var information = stat()
      if lstat(existing.path, &information) == 0 {
        guard information.st_mode & S_IFMT == S_IFDIR else {
          throw CloneFailure(
            "installation_directory_unavailable",
            L10n.text(.installationDirectoryUnavailable, directory.path))
        }
        break
      }
      if errno == ENOTDIR {
        throw CloneFailure(
          "installation_directory_unavailable",
          L10n.text(.installationDirectoryUnavailable, directory.path))
      }
      guard errno == ENOENT, existing.path != "/" else {
        throw unreadableCapacity(directory)
      }
      existing.deleteLastPathComponent()
    }
    // 只使用当前空闲容量，不将系统可能清理的缓存或 APFS 共享块当作可用空间。
    let values = try existing.resourceValues(forKeys: [.volumeAvailableCapacityKey])
    guard let available = values.volumeAvailableCapacity, available >= 0 else {
      throw unreadableCapacity(directory)
    }
    return Int64(available)
  }

  private static func unreadableApplication(_ app: URL) -> CloneFailure {
    CloneFailure("application_size_unavailable", L10n.text(.applicationSizeUnavailable, app.path))
  }

  private static func unreadableCapacity(_ directory: URL) -> CloneFailure {
    CloneFailure("disk_capacity_unavailable", L10n.text(.diskCapacityUnavailable, directory.path))
  }
}
