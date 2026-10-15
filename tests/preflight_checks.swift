import Foundation

@testable import appclonecore

func expect(
  _ condition: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line
) throws {
  guard try condition() else {
    throw CloneFailure("test_failed", "检查失败：\(file):\(line)")
  }
}

func expectFailure(_ code: String, body: () throws -> Void) throws {
  do {
    try body()
    throw CloneFailure("test_failed", "应返回 \(code)")
  } catch let error as CloneFailure {
    guard error.code == code else {
      throw CloneFailure("test_failed", "预期 \(code)，实际为 \(error.code)：\(error.message)")
    }
  }
}

private struct Fixture {
  let directory: URL
  let source: URL
  let root: URL
  var engine: CloneEngine { CloneEngine(root: root) }
  var workspace: Workspace { Workspace(root: root) }

  init() throws {
    directory = BundleFiles.canonical(FileManager.default.temporaryDirectory)
      .appending(path: "app-clone-preflight-\(UUID().uuidString.lowercased())")
    source = directory.appending(path: "source.app")
    root = directory.appending(path: "workspace")
    let executable = source.appending(path: "Contents/MacOS/fixture")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: executable.path)
    try BundleFiles.writePlist(
      [
        "CFBundleIdentifier": "local.app-clone.fixture", "CFBundleExecutable": "fixture",
        "CFBundlePackageType": "APPL",
      ], to: BundleFiles.plistURL(source))
  }

  func cleanup() { try? FileManager.default.removeItem(at: directory) }

  func setBundleID(_ id: String) throws {
    var plist = try BundleFiles.readPlist(BundleFiles.plistURL(source))
    plist["CFBundleIdentifier"] = id
    try BundleFiles.writePlist(plist, to: BundleFiles.plistURL(source))
  }
}

@main
struct PreflightChecks {
  static func main() throws {
    try ElectronInspectorTests().run()
    try AppPlatformTests().run()
    try checkBlocklist()
    try checkPolicySwitches()
    try checkStorage()
    try checkRebuilds()
    print("Swift 前置检查通过：禁止列表、平台、Electron、策略开关、容量、取消及重建保护。")
  }

  private static func checkBlocklist() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    for id in ["ru.keepcoder.Telegram", "RU.KEEPCODER.TELEGRAM"] {
      try fixture.setBundleID(id)
      try expectFailure("blocked_application") {
        _ = try fixture.engine.create(source: fixture.source, name: "blocked")
      }
      try expect(!BundleFiles.exists(fixture.root))
      try expect(try AppInspector.inspect(fixture.source).bundleID == id)
    }
    for id in [
      "org.telegram.desktop", "ru.keepcoder.TelegramOther", "ru.keepcoder.Telegram.helper",
    ] {
      try fixture.setBundleID(id)
      try expect(try ClonePreflight().inspectSource(fixture.source).application.bundleID == id)
    }
    try fixture.setBundleID("ru.keepcoder.Telegram")
    for policy in [
      ClonePolicy(checksBlockedApplications: false), ClonePolicy(blockedBundleIdentifiers: []),
    ] {
      _ = try ClonePreflight(policy: policy).inspectSource(fixture.source)
    }
    // 原 ID 优先于 plist；列表优先于可执行文件解析和完整 macOS 布局校验。
    try FileManager.default.removeItem(at: BundleFiles.plistURL(fixture.source))
    try expectFailure("blocked_application") {
      _ = try ClonePreflight().inspectSource(
        fixture.source, originalBundleID: "ru.keepcoder.Telegram")
    }
    try BundleFiles.writePlist(
      ["CFBundleIdentifier": "ru.keepcoder.Telegram"], to: BundleFiles.plistURL(fixture.source))
    try Data([0xcf, 0xfa, 0xed, 0xfe]).write(
      to: fixture.source.appending(path: "Contents/MacOS/fixture"))
    try expectFailure("blocked_application") {
      _ = try ClonePreflight().inspectSource(fixture.source)
    }
  }

  private static func checkPolicySwitches() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let forbiddenCapacity = StorageInspector { _ in throw CloneFailure("test_failed", "不应查询容量") }
    let forbiddenSystem: @Sendable (URL, String) throws -> Bool = { _, _ in
      throw CloneFailure("test_failed", "不应查询系统标记")
    }
    let disabled = ClonePreflight(
      policy: ClonePolicy(
        isEnabled: false, blockedBundleIdentifiers: ["local.app-clone.fixture"],
        maximumApplicationBytes: 1),
      storage: forbiddenCapacity, isSystemApplication: forbiddenSystem)
    let inspection = try disabled.inspectSource(fixture.source)
    try expect(inspection.applicationBytes == nil)
    try disabled.checkDestination(for: inspection, workspace: fixture.workspace)
    let engine = CloneEngine(root: fixture.root, preflight: disabled)
    let record = try engine.create(source: fixture.source, name: "disabled")
    let app = try fixture.workspace.appURL(record)
    _ = try engine.rename(app: app, name: "disabled-renamed")

    try expectFailure("unsupported_system_app") {
      _ = try ClonePreflight(isSystemApplication: { _, _ in true }).inspectSource(fixture.source)
    }
    _ = try ClonePreflight(
      policy: ClonePolicy(checksSystemApplications: false), isSystemApplication: forbiddenSystem
    ).inspectSource(fixture.source)
    try expectFailure("application_too_large") {
      _ = try ClonePreflight(
        policy: ClonePolicy(checksDiskSpace: false, maximumApplicationBytes: 1),
        storage: forbiddenCapacity
      ).inspectSource(fixture.source)
    }
    let noDisk = ClonePreflight(
      policy: ClonePolicy(checksDiskSpace: false), storage: forbiddenCapacity)
    try noDisk.checkDestination(
      for: noDisk.inspectSource(fixture.source), workspace: fixture.workspace)
    let noStorage = ClonePreflight(
      policy: ClonePolicy(checksApplicationSize: false, checksDiskSpace: false),
      storage: forbiddenCapacity)
    try expect(try noStorage.inspectSource(fixture.source).applicationBytes == nil)

    let framework = fixture.source.appending(
      path: "Contents/Frameworks/Electron Framework.framework")
    try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
    try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: framework.appending(path: "Electron Framework"))
    try expectFailure("unsupported_electron_app") {
      _ = try ClonePreflight().inspectSource(fixture.source)
    }
    // 仅测试代码开关，不尝试克隆、修补或运行 Electron。
    _ = try ClonePreflight(policy: ClonePolicy(checksElectronApplications: false)).inspectSource(
      fixture.source)
    _ = try disabled.inspectSource(fixture.source)
    let token = CancellationToken()
    token.cancel()
    try expectFailure("cancelled") { _ = try disabled.inspectSource(fixture.source, token: token) }
  }

  private static func checkStorage() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let inspection = try ClonePreflight().inspectSource(fixture.source)
    let required = inspection.applicationBytes! * 2 + 1_000_000_000
    try ClonePreflight(storage: StorageInspector { _ in required }).checkDestination(
      for: inspection, workspace: fixture.workspace)
    try expectFailure("insufficient_disk_space") {
      try ClonePreflight(storage: StorageInspector { _ in required - 1 }).checkDestination(
        for: inspection, workspace: fixture.workspace)
    }
    for storage in [
      StorageInspector { _ in -1 },
      StorageInspector { _ in throw CocoaError(.fileReadNoPermission) },
    ] {
      try expectFailure("disk_capacity_unavailable") {
        try ClonePreflight(storage: storage).checkDestination(
          for: inspection, workspace: fixture.workspace)
      }
    }
    try expect(try StorageInspector().availableCapacity(at: fixture.workspace.apps) > 0)
    try expect(!BundleFiles.exists(fixture.root))
    let token = CancellationToken()
    token.cancel()
    try expectFailure("cancelled") {
      try ClonePreflight(
        storage: StorageInspector { _ in throw CloneFailure("test_failed", "取消后仍查询磁盘") }
      )
      .checkDestination(for: inspection, workspace: fixture.workspace, token: token)
    }
    let huge = CloneSourceInspection(
      application: inspection.application, applicationBytes: Int64.max)
    try expectFailure("disk_capacity_unavailable") {
      try ClonePreflight().checkDestination(for: huge, workspace: fixture.workspace)
    }
    let root = fixture.root
    try expectFailure("insufficient_disk_space") {
      try ClonePreflight(storage: StorageInspector { $0 == root ? 0 : Int64.max })
        .checkDestination(for: inspection, workspace: fixture.workspace)
    }
    let noSpace = CloneEngine(
      root: root, preflight: ClonePreflight(storage: StorageInspector { _ in 0 }))
    try expectFailure("insufficient_disk_space") {
      _ = try noSpace.create(source: fixture.source, name: "no-space")
    }
    try expect(try noSpace.list().isEmpty)
    try expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.staging.path).isEmpty)
    try expect(!BundleFiles.exists(fixture.workspace.journalURL))

    let nested = fixture.source.appending(path: "Contents/.hidden/helper.app")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let payload = nested.appending(path: "payload")
    try Data().write(to: payload)
    let file = try FileHandle(forWritingTo: payload)
    defer { try? file.close() }
    try file.truncate(atOffset: 3_000_000_000)
    try FileManager.default.createSymbolicLink(
      atPath: fixture.source.appending(path: "Contents/alias").path,
      withDestinationPath: ".hidden/helper.app")
    let size = try ClonePreflight().inspectSource(fixture.source).applicationBytes!
    try expect(size >= 3_000_000_000 && size < 3_010_000_000)
    try file.truncate(atOffset: 5_000_000_001)
    try expectFailure("application_too_large") {
      _ = try ClonePreflight().inspectSource(fixture.source)
    }
    let noLimit = ClonePreflight(
      policy: ClonePolicy(checksApplicationSize: false), storage: StorageInspector { _ in 0 })
    let large = try noLimit.inspectSource(fixture.source)
    try expect(large.applicationBytes! >= 5_000_000_001)
    try expectFailure("insufficient_disk_space") {
      try noLimit.checkDestination(for: large, workspace: fixture.workspace)
    }
    try expectFailure("cancelled") {
      _ = try StorageInspector.applicationSize(at: fixture.source, token: token)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: nested.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nested.path)
    }
    try expectFailure("application_size_unavailable") {
      _ = try noLimit.inspectSource(fixture.source)
    }
  }

  private static func checkRebuilds() throws {
    for reason in ["blocked_application", "insufficient_disk_space"] {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      if reason == "blocked_application" { try fixture.setBundleID("ru.keepcoder.Telegram") }
      let allowed = CloneEngine(
        root: fixture.root,
        preflight: ClonePreflight(policy: ClonePolicy(checksBlockedApplications: false)))
      let record = try allowed.create(source: fixture.source, name: "existing")
      let app = try fixture.workspace.appURL(record)
      let plist = try Data(contentsOf: BundleFiles.plistURL(app))
      let catalog = try Data(contentsOf: fixture.root.appending(path: "state.json"))
      let engine =
        reason == "blocked_application"
        ? fixture.engine
        : CloneEngine(
          root: fixture.root, preflight: ClonePreflight(storage: StorageInspector { _ in 0 }))
      try expectFailure(reason) { _ = try engine.rename(app: app, name: "changed") }
      try expectFailure(reason) {
        _ = try engine.replaceIcon(app: app, icon: fixture.directory.appending(path: "missing.png"))
      }
      try expectFailure(reason) { _ = try engine.configureEnvironment(app: app, appLanguage: "en") }
      try expect(try Data(contentsOf: BundleFiles.plistURL(app)) == plist)
      try expect(try Data(contentsOf: fixture.root.appending(path: "state.json")) == catalog)
      try expect(
        try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.staging.path).isEmpty)
      try expect(!BundleFiles.exists(fixture.workspace.journalURL))
      try expect(try engine.verify(app: app).id == record.id)
      try expect(try engine.configureEnvironment(app: app).id == record.id)
      _ = try engine.remove(app: app)
      try expect(try engine.list().isEmpty)
    }
  }
}
