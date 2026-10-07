import Foundation

@testable import appclonecore

private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw CloneFailure("test_failed", message) }
}

@main
struct ApplicationLinkChecks {
  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString.lowercased())
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let app = root.appendingPathComponent("data/test.app")
    try fm.createDirectory(at: app, withIntermediateDirectories: true)
    let payload = app.appendingPathComponent("keep")
    try Data("unchanged".utf8).write(to: payload)
    let links = ApplicationLink(directory: root.appendingPathComponent("applications/app-clone"))
    let link = try links.install(for: app)
    let destination = try fm.destinationOfSymbolicLink(atPath: link.path)
    try require(destination == app.path, "入口必须是指向原位置的符号链接。")
    let repeated = try links.install(for: app)
    try require(repeated == link, "重复创建应保留同一链接。")
    let data = try Data(contentsOf: link.appendingPathComponent("keep"))
    try require(data == Data("unchanged".utf8), "链接应能访问原应用内容。")
    try links.remove(for: app)
    try require(!BundleFiles.exists(link) && BundleFiles.exists(payload), "移除链接不能移除应用。")

    try fm.createDirectory(at: link, withIntermediateDirectories: false)
    try expectConflict(links, app)
    try links.remove(for: app)
    try require(BundleFiles.exists(link), "不能移除同名真实目录。")
    try fm.removeItem(at: link)
    let other = root.appendingPathComponent("unrelated.app")
    try fm.createSymbolicLink(at: link, withDestinationURL: other)
    try expectConflict(links, app)
    try links.remove(for: app)
    let unrelated = try fm.destinationOfSymbolicLink(atPath: link.path)
    try require(unrelated == other.path, "不能覆盖或删除指向其他应用的链接。")
    try fm.removeItem(at: link)

    _ = try links.install(for: app)
    let renamed = app.deletingLastPathComponent().appendingPathComponent("renamed.app")
    let renamedLink = links.directory.appendingPathComponent("renamed.app")
    try fm.createDirectory(at: renamedLink, withIntermediateDirectories: false)
    try expectConflict(links, renamed, replacing: app)
    try require(links.contains(for: app), "改名入口冲突时应保留旧链接。")
    try fm.removeItem(at: renamedLink)
    try fm.moveItem(at: app, to: renamed)
    _ = try links.install(for: renamed, replacing: app)
    try require(!BundleFiles.exists(link) && links.contains(for: renamed), "改名应替换软链接。")
    let caseChanged = renamed.deletingLastPathComponent().appendingPathComponent("Renamed.app")
    let temporary = root.appendingPathComponent("temporary.app")
    try fm.moveItem(at: renamed, to: temporary)
    try fm.moveItem(at: temporary, to: caseChanged)
    let caseLink = try links.install(for: caseChanged, replacing: renamed)
    try require(links.contains(for: caseChanged), "仅改大小写也应更新链接目标。")
    let renamedData = try Data(contentsOf: caseLink.appendingPathComponent("keep"))
    try require(renamedData == Data("unchanged".utf8), "改名链接应仍能打开原内容。")
    try fm.removeItem(at: caseChanged)
    try links.remove(for: caseChanged)
    try require(!BundleFiles.exists(caseLink), "删除应用后必须能清理悬空链接。")
    print("Swift 链接检查通过：创建、改名、大小写改名、冲突保护、悬空链接清理。")
  }

  private static func expectConflict(
    _ links: ApplicationLink, _ app: URL, replacing previous: URL? = nil
  ) throws {
    do {
      _ = try links.install(for: app, replacing: previous)
      throw CloneFailure("test_failed", "入口被占用时不应覆盖。")
    } catch let error as CloneFailure {
      try require(error.code == "link_conflict", "入口冲突应返回 link_conflict。")
    }
  }
}
