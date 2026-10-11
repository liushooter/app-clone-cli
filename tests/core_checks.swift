import Foundation

@testable import appclonecore

private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw CloneFailure("test_failed", message) }
}

@main
struct CoreChecks {
  static func main() throws {
    try checkLocalization()
    try checkLocations()
    let runner = ProcessRunner()
    let cancelled = CancellationToken()
    cancelled.cancel()
    do {
      _ = try runner.run("/usr/bin/true", [], token: cancelled)
      throw CloneFailure("test_failed", "预先取消后不应执行进程。")
    } catch let error as CloneFailure {
      try require(error.code == "cancelled", "预先取消没有返回 cancelled。")
    }

    let active = CancellationToken()
    let started = Date()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { active.cancel() }
    do {
      _ = try runner.run("/bin/sleep", ["30"], token: active)
      throw CloneFailure("test_failed", "执行中的进程未取消。")
    } catch let error as CloneFailure {
      try require(error.code == "cancelled", "执行中取消没有返回 cancelled。")
    }
    try require(Date().timeIntervalSince(started) < 5, "取消后进程没有及时退出。")

    do {
      _ = try runner.run("/bin/sleep", ["30"], token: CancellationToken(), timeout: 0.1)
      throw CloneFailure("test_failed", "超时进程没有退出。")
    } catch let error as CloneFailure {
      try require(error.code == "timeout", "超时没有返回 timeout。")
    }

    let result = try runner.run(
      "/bin/dd", ["if=/dev/zero", "bs=65536", "count=2"],
      token: CancellationToken())
    try require(
      result.status == 0 && result.output.utf8.count == 65_536,
      "大于 pipe 容量的输出应完成且读取上限为 64 KiB。")
    print("Swift 核心检查通过：预取消、执行中取消、超时、输出容量。")
  }

  private static func checkLocalization() throws {
    let cases: [([String: String], [String], AppLanguage)] = [
      (["LC_ALL": "en_US.UTF-8", "LC_MESSAGES": "zh_CN", "LANG": "zh_CN"], ["zh"], .en),
      (["LC_ALL": "", "LC_MESSAGES": "zh_CN", "LANG": "en_US"], ["en"], .zh),
      (["LANG": "zh-Hans-CN"], ["en"], .zh),
      ([:], ["zh-Hant-TW"], .zh),
      ([:], ["en-GB"], .en),
      (["LANG": "C"], ["zh"], .en),
      (["LANG": "de_DE.UTF-8"], ["zh"], .en),
      ([:], [], .en),
    ]
    for (environment, preferred, expected) in cases {
      try require(
        AppLanguage.detect(environment: environment, preferredLanguages: preferred) == expected,
        "语言检测优先级不正确。")
    }
    for message in L10n.Message.allCases {
      let zh = L10n.translation(message, language: .zh)
      let en = L10n.translation(message, language: .en)
      try require(!zh.isEmpty && !en.isEmpty, "缺少翻译：\(message)")
      try require(
        zh.components(separatedBy: "{}").count == en.components(separatedBy: "{}").count,
        "翻译参数数量不一致：\(message)")
    }
    try L10n.$language.withValue(.en) {
      try require(
        L10n.text(.nameConflict, "工作 {} %s") == "A clone with this name already exists: 工作 {} %s",
        "用户参数不应作为翻译模板解析。")
      let token = CancellationToken()
      // Signal callbacks run outside the task-local scope; the token must keep its language.
      L10n.$language.withValue(.zh) { token.cancel() }
      do {
        try token.check()
        throw CloneFailure("test_failed", "取消没有返回错误。")
      } catch let error as CloneFailure {
        try require(error.message == "Operation cancelled.", "取消提示丢失语言。")
      }
      do {
        _ = try ProcessRunner().run(
          "/bin/sleep", ["30"], token: CancellationToken(), timeout: 0.05)
        throw CloneFailure("test_failed", "超时没有返回错误。")
      } catch let error as CloneFailure {
        try require(error.message == "Command timed out: /bin/sleep", "超时提示丢失语言。")
      }
    }
    print("Swift 国际化检查通过：语言选择、翻译完整性、参数、取消和超时。")
  }

  private static func checkLocations() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
      "app-clone-location-" + UUID().uuidString.lowercased())
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("origin.app")
    let executable = source.appendingPathComponent("Contents/MacOS/fixture")
    try fm.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(atPath: "/usr/bin/true", toPath: executable.path)
    try BundleFiles.writePlist(
      [
        "CFBundleIdentifier": "local.app-clone.location-fixture",
        "CFBundleExecutable": "fixture",
        "CFBundlePackageType": "APPL",
      ], to: BundleFiles.plistURL(source))
    let engine = CloneEngine(root: root.appendingPathComponent("workspace"))
    let directory = try engine.location()
    try require(directory == engine.root.appendingPathComponent("apps"), "空工作空间应返回分身目录。")
    try BundleFiles.requireRegular(directory, directory: true)
    let record = try engine.create(source: source, name: "location test")
    let app = directory.appendingPathComponent(record.appFileName!)
    let link = root.appendingPathComponent("shortcut.app")
    try fm.createSymbolicLink(at: link, withDestinationURL: app)
    let catalogURL = engine.root.appendingPathComponent("state.json")
    let catalog = try Data(contentsOf: catalogURL)
    for path in [app, link] {
      let location = try engine.location(of: path)
      try require(location == app, "定位必须返回真实分身位置。")
      let inferred = try CloneEngine.workspaceRoot(for: path)
      try require(inferred.path == engine.root.path, "分身和软链接应定位到同一工作空间。")
    }
    let unchanged = try Data(contentsOf: catalogURL)
    try require(unchanged == catalog, "定位不能修改分身清单。")
    let other = CloneEngine(root: root.appendingPathComponent("other-workspace"))
    for (selected, path) in [(engine, source), (other, app)] {
      do {
        _ = try selected.location(of: path)
        throw CloneFailure("test_failed", "定位必须拒绝原应用和不匹配的工作空间。")
      } catch let error as CloneFailure {
        try require(error.code == "not_managed", "非受管理位置应返回 not_managed。")
      }
    }
    var plist = try BundleFiles.readPlist(BundleFiles.plistURL(app))
    plist[BundleFiles.ownershipKey] = "mismatch"
    try BundleFiles.writePlist(plist, to: BundleFiles.plistURL(app))
    do {
      _ = try engine.location(of: link)
      throw CloneFailure("test_failed", "定位必须检查分身归属。")
    } catch let error as CloneFailure {
      try require(error.code == "ownership_mismatch", "归属不匹配应返回 ownership_mismatch。")
    }
    print("Swift 定位检查通过：空目录、分身路径、软链接、工作空间推断和归属校验。")
  }
}
