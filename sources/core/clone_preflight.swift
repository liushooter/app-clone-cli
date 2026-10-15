import Foundation

/// 统一编排来源与目标检查。只读、不持有锁、不创建目录，由引擎决定事务时机。
struct ClonePreflight: Sendable {
  private let policy: ClonePolicy
  private let storage: StorageInspector
  private let isSystemApplication: @Sendable (URL, String) throws -> Bool

  init(
    policy: ClonePolicy = .current, storage: StorageInspector = StorageInspector(),
    isSystemApplication: @escaping @Sendable (URL, String) throws -> Bool = BundleFiles
      .isSystemApplication
  ) {
    self.policy = policy
    self.storage = storage
    self.isSystemApplication = isSystemApplication
  }

  func inspectSource(
    _ url: URL, originalBundleID: String? = nil,
    token: CancellationToken = CancellationToken(), onEvent: EventHandler = { _ in }
  ) throws -> CloneSourceInspection {
    try token.check()
    onEvent(CloneEvent("inspect", L10n.text(.inspectProgress)))
    let app = try AppInspector.applicationURL(url)
    // 已有分身先检查资料库中的原 ID；命中后无需读取应用内容。
    try checkBlockedApplication(originalBundleID)
    let metadata: [AppPlatformInspector.Metadata]
    if policy.isEnabled, policy.checksBlockedApplications || policy.checksIOSApplications {
      metadata = try AppPlatformInspector.metadata(in: app) { entry in
        try token.check()
        try checkBlockedApplication(entry.plist["CFBundleIdentifier"] as? String)
      }
    } else {
      metadata = []
    }
    // 列表匹配完成后才读取 Mach-O；iOS 包装仍先于完整 macOS 包结构校验。
    if policy.isEnabled, policy.checksIOSApplications,
      try AppPlatformInspector.isIOSApplication(app, metadata: metadata)
    {
      throw CloneFailure("unsupported_ios_app", L10n.text(.unsupportedIOSApp))
    }
    let descriptor = try AppInspector.inspect(app)
    if policy.isEnabled, policy.checksSystemApplications,
      try isSystemApplication(app, descriptor.executable)
    {
      throw CloneFailure(
        "unsupported_system_app", L10n.text(.unsupportedSystemApp, descriptor.path))
    }
    if policy.isEnabled, policy.checksElectronApplications,
      try ElectronInspector.isElectron(app, token: token)
    {
      throw CloneFailure("unsupported_electron_app", L10n.text(.unsupportedElectronApp))
    }
    let bytes: Int64?
    if policy.isEnabled, policy.checksApplicationSize || policy.checksDiskSpace {
      try token.check()
      onEvent(CloneEvent("storage", L10n.text(.storageProgress)))
      let limit = policy.checksApplicationSize ? policy.maximumApplicationBytes : nil
      let measured = try StorageInspector.applicationSize(
        at: app, stoppingAfter: limit, token: token)
      if let limit, measured > limit {
        throw CloneFailure(
          "application_too_large", L10n.text(.applicationTooLarge, formattedBytes(limit)))
      }
      bytes = measured
    } else {
      bytes = nil
    }
    try token.check()
    return CloneSourceInspection(application: descriptor, applicationBytes: bytes)
  }

  /// 必须在工作空间锁内使用最新保存目录调用，并在创建暂存任务之前完成。
  func checkDestination(
    for source: CloneSourceInspection, workspace: Workspace,
    token: CancellationToken = CancellationToken(), onEvent: EventHandler = { _ in }
  ) throws {
    try token.check()
    guard policy.isEnabled, policy.checksDiskSpace else { return }
    onEvent(CloneEvent("storage", L10n.text(.storageProgress)))
    guard let bytes = source.applicationBytes, bytes >= 0 else {
      throw CloneFailure(
        "application_size_unavailable",
        L10n.text(.applicationSizeUnavailable, source.application.path)
      )
    }
    let (copies, multiplicationOverflow) = bytes.multipliedReportingOverflow(
      by: policy.copySpaceMultiplier)
    let (required, additionOverflow) = copies.addingReportingOverflow(policy.reservedDiskBytes)
    guard policy.copySpaceMultiplier >= 1, policy.reservedDiskBytes >= 0,
      !multiplicationOverflow, !additionOverflow
    else {
      throw CloneFailure(
        "disk_capacity_unavailable", L10n.text(.diskCapacityUnavailable, workspace.apps.path))
    }
    for (directory, minimum) in [
      (workspace.apps, required), (workspace.root, policy.reservedDiskBytes),
    ] {
      try token.check()
      let available = try storage.availableCapacity(at: directory)
      try token.check()
      guard available >= minimum else {
        throw CloneFailure(
          "insufficient_disk_space",
          L10n.text(
            .insufficientDiskSpace, directory.path, formattedBytes(minimum),
            formattedBytes(available)))
      }
    }
  }

  private func formattedBytes(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .decimal, allowedUnits: [.gb, .mb, .kb, .bytes]))
  }

  private func checkBlockedApplication(_ bundleID: String?) throws {
    guard policy.isEnabled, policy.checksBlockedApplications, let bundleID else { return }
    if policy.blockedBundleIdentifiers.contains(where: {
      $0.caseInsensitiveCompare(bundleID) == .orderedSame
    }) {
      throw CloneFailure("blocked_application", L10n.text(.blockedApplication, bundleID))
    }
  }
}
