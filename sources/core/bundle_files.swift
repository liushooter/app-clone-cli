import Darwin
import Foundation

enum BundleFiles {
  static let ownershipKey = "appclone_id"
  static let customIcon = "app-clone.icns"

  static func canonical(_ url: URL) -> URL {
    if let resolved = Darwin.realpath(url.path, nil) {
      defer { free(resolved) }
      return URL(fileURLWithPath: String(cString: resolved))
    }
    let parent = url.deletingLastPathComponent()
    guard parent.path != url.path else { return url }
    return canonical(parent).appendingPathComponent(url.lastPathComponent)
  }

  static func isWithin(_ child: URL, _ parent: URL) -> Bool {
    let components = canonical(child).pathComponents
    let parentComponents = canonical(parent).pathComponents
    return components.count > parentComponents.count
      && components.starts(with: parentComponents)
  }

  static func exists(_ url: URL) -> Bool {
    // Unlike fileExists, attributesOfItem sees a dangling symlink.
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
  }

  static func sameItem(_ first: URL, _ second: URL) -> Bool {
    let fm = FileManager.default
    guard let a = try? fm.attributesOfItem(atPath: first.path),
      let b = try? fm.attributesOfItem(atPath: second.path),
      let aFile = a[.systemFileNumber] as? NSNumber, let bFile = b[.systemFileNumber] as? NSNumber,
      let aVolume = a[.systemNumber] as? NSNumber, let bVolume = b[.systemNumber] as? NSNumber
    else { return false }
    return aFile == bFile && aVolume == bVolume
  }

  static func requireRegular(_ url: URL, directory: Bool = false) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let expected: FileAttributeType = directory ? .typeDirectory : .typeRegular
    guard attributes[.type] as? FileAttributeType == expected else {
      throw CloneFailure(
        "invalid_path", L10n.text(directory ? .invalidDirectoryPath : .invalidFilePath, url.path))
    }
  }

  static func plistURL(_ app: URL) -> URL {
    app.appendingPathComponent("Contents/Info.plist")
  }

  static func readPlist(_ url: URL) throws -> [String: Any] {
    try requireRegular(url)
    let data = try Data(contentsOf: url)
    guard data.count <= 8 * 1024 * 1024,
      let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else {
      throw CloneFailure("invalid_plist", L10n.text(.invalidPlist, url.path))
    }
    return plist
  }

  static func writePlist(_ plist: [String: Any], to url: URL) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: url, options: .atomic)
  }

  static func validateBundleID(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 255,
      value.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil
    else {
      throw CloneFailure(
        "invalid_bundle_id", L10n.text(.invalidBundleID, value))
    }
  }

  static func validateID(_ id: String) throws {
    guard UUID(uuidString: id)?.uuidString.lowercased() == id else {
      throw CloneFailure("invalid_id", L10n.text(.invalidID))
    }
  }

  static func validateLinks(in app: URL, token: CancellationToken) throws {
    let fm = FileManager.default
    guard
      let iterator = fm.enumerator(
        at: app, includingPropertiesForKeys: [.isSymbolicLinkKey],
        options: [], errorHandler: { _, _ in false })
    else {
      throw CloneFailure("read_failed", L10n.text(.readDirectoryFailed))
    }
    for case let entry as URL in iterator {
      try token.check()
      let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        let resolved = entry.resolvingSymlinksInPath()
        guard isWithin(resolved, app), fm.fileExists(atPath: resolved.path) else {
          throw CloneFailure(
            "external_symlink", L10n.text(.externalSymlink, entry.path))
        }
      }
    }
  }

  static func checkOwnership(_ app: URL, record: CloneRecord) throws {
    try requireRegular(app, directory: true)
    try requireRegular(app.appendingPathComponent("Contents"), directory: true)
    let plist = try readPlist(plistURL(app))
    guard plist[ownershipKey] as? String == record.id,
      plist["CFBundleIdentifier"] as? String == record.bundleID
    else {
      throw CloneFailure(
        "ownership_mismatch", L10n.text(.ownershipMismatch, app.path))
    }
  }
}

public enum AppInspector {
  public static func inspect(_ path: URL) throws -> AppDescriptor {
    let app = BundleFiles.canonical(path)
    guard app.pathExtension.lowercased() == "app" else {
      throw CloneFailure("not_app", L10n.text(.notApp))
    }
    try BundleFiles.requireRegular(app, directory: true)
    try BundleFiles.requireRegular(app.appendingPathComponent("Contents"), directory: true)
    try BundleFiles.requireRegular(app.appendingPathComponent("Contents/MacOS"), directory: true)
    let plist = try BundleFiles.readPlist(BundleFiles.plistURL(app))
    guard let bundleID = plist["CFBundleIdentifier"] as? String,
      let executable = plist["CFBundleExecutable"] as? String,
      !executable.isEmpty, executable != ".", executable != "..",
      !executable.contains("/"), !executable.contains("\0")
    else {
      throw CloneFailure("invalid_bundle", L10n.text(.invalidBundle))
    }
    try BundleFiles.validateBundleID(bundleID)
    let executableURL = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(
      executable)
    try BundleFiles.requireRegular(executableURL)
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      throw CloneFailure(
        "not_executable", L10n.text(.notExecutable, executable))
    }
    return AppDescriptor(
      path: app.path,
      name: plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String
        ?? app.deletingPathExtension().lastPathComponent,
      bundleID: bundleID,
      version: plist["CFBundleShortVersionString"] as? String ?? "未知",
      build: plist["CFBundleVersion"] as? String ?? "未知",
      executable: executable,
      iconFile: plist["CFBundleIconFile"] as? String,
      iconName: plist["CFBundleIconName"] as? String)
  }
}
