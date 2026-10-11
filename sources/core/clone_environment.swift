import CryptoKit
import Foundation

public struct CloneEnvironment: Codable, Sendable, Equatable {
  public var dataDirectory: String?
  public var proxy: String?
  public var locale: String?
  public var dylibSHA256: String?

  var variables: [String: String] {
    var result: [String: String] = [:]
    if dataDirectory != nil {
      result["HOME"] = "{{APP_CLONE_DATA_DIR}}/home"
      result["TMPDIR"] = "{{APP_CLONE_DATA_DIR}}/tmp/"
    }
    if let proxy {
      result["HTTP_PROXY"] = proxy
      result["HTTPS_PROXY"] = proxy
    }
    if let locale {
      result["LANG"] = locale
      result["LC_ALL"] = locale
    }
    return result
  }
}

enum EnvironmentInstaller {
  static let name = "libappclone_env.dylib"
  static let loadPath = "@executable_path/../Frameworks/" + name

  static func validate(_ settings: CloneEnvironment, workspace: URL, source: URL) throws {
    if let proxy = settings.proxy {
      guard proxy.utf8.count <= 8192, let url = URLComponents(string: proxy),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
        let host = url.host, !host.isEmpty,
        url.port.map({ (1...65535).contains($0) }) ?? true,
        url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
        !proxy.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      else { throw CloneFailure("invalid_proxy", L10n.text(.invalidProxy)) }
    }
    if let locale = settings.locale {
      guard !locale.isEmpty, locale.utf8.count <= 128,
        locale.range(of: "^[A-Za-z][A-Za-z0-9_.@-]*$", options: .regularExpression) != nil
      else { throw CloneFailure("invalid_locale", L10n.text(.invalidLocale)) }
    }
    if let path = settings.dataDirectory {
      let directory = URL(fileURLWithPath: path)
      let forbidden = [workspace, source, FileManager.default.homeDirectoryForCurrentUser]
      guard path.hasPrefix("/"), !path.contains("\0"), path != "/",
        forbidden.allSatisfy({ directory != BundleFiles.canonical($0) }),
        !BundleFiles.isWithin(directory, source), !BundleFiles.isWithin(source, directory),
        !BundleFiles.isWithin(workspace, directory),
        !BundleFiles.isWithin(directory, workspace)
          || BundleFiles.isWithin(directory, workspace.appendingPathComponent("data"))
      else { throw CloneFailure("invalid_data_directory", L10n.text(.invalidDataDirectory)) }
      for target in [
        directory, directory.appendingPathComponent("home"),
        directory.appendingPathComponent("tmp"),
      ]
      where BundleFiles.exists(target) {
        try BundleFiles.requireRegular(target, directory: true)
      }
    }
  }

  static func prepareDirectories(_ settings: CloneEnvironment) throws {
    guard let path = settings.dataDirectory else { return }
    let root = URL(fileURLWithPath: path)
    for directory in [
      root, root.appendingPathComponent("home"), root.appendingPathComponent("tmp"),
    ] {
      if !BundleFiles.exists(directory) {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      }
      try BundleFiles.requireRegular(directory, directory: true)
    }
  }

  static func install(
    _ settings: CloneEnvironment?, replacing previous: CloneEnvironment?,
    into app: URL, job: URL, token: CancellationToken
  ) throws {
    let fm = FileManager.default
    let descriptor = try AppInspector.inspect(app)
    let executable = app.appendingPathComponent("Contents/MacOS/" + descriptor.executable)
    let frameworks = app.appendingPathComponent("Contents/Frameworks")
    let library = frameworks.appendingPathComponent(name)
    if previous == nil, BundleFiles.exists(library) {
      throw CloneFailure("environment_conflict", L10n.text(.environmentConflict))
    }
    let original = try Data(contentsOf: executable)
    let patched: Data
    do {
      patched =
        try settings == nil
        ? MachOInjector.removingDylib(loadPath, from: original)
        : MachOInjector.insertingDylib(loadPath, into: original)
    } catch {
      throw CloneFailure("unsupported_macho", L10n.text(.unsupportedMachO))
    }
    if previous == nil, patched == original {
      throw CloneFailure("environment_conflict", L10n.text(.environmentConflict))
    }
    if let settings {
      if !BundleFiles.exists(frameworks) {
        try fm.createDirectory(at: frameworks, withIntermediateDirectories: false)
      }
      try BundleFiles.requireRegular(frameworks, directory: true)
      let source = job.appendingPathComponent("env.c")
      let generated = try EnvironmentSource.generate(
        variables: settings.variables,
        dataDirectory: URL(fileURLWithPath: settings.dataDirectory ?? "/"))
      try generated.write(to: source, atomically: true, encoding: .utf8)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
      let runner = ProcessRunner()
      let compiler = try runner.run("/usr/bin/xcrun", ["--find", "clang"], token: token)
      let sdk = try runner.run(
        "/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"], token: token)
      _ = try runner.run(
        compiler.output,
        [
          "-isysroot", sdk.output, "-mmacosx-version-min=14.0", "-arch", "arm64", "-arch", "x86_64",
          "-dynamiclib", "-O2", "-Wall", "-Wextra", "-Werror", "-install_name", loadPath,
          source.path, "-o", library.path,
        ], token: token)
      _ = try runner.run(
        "/usr/bin/codesign", ["--force", "--sign", "-", library.path], token: token)
    } else if previous != nil {
      try fm.removeItem(at: library)
    }
    if patched != original {
      // Atomic replacement avoids modifying a hard-linked executable outside the staging copy.
      let permissions = try fm.attributesOfItem(atPath: executable.path)[.posixPermissions]!
      try patched.write(to: executable, options: .atomic)
      try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: executable.path)
    }
  }

  static func digest(in app: URL) throws -> String {
    let frameworks = app.appendingPathComponent("Contents/Frameworks")
    try BundleFiles.requireRegular(frameworks, directory: true)
    let library = frameworks.appendingPathComponent(name)
    try BundleFiles.requireRegular(library)
    return SHA256.hash(data: try Data(contentsOf: library)).map { String(format: "%02x", $0) }
      .joined()
  }

  static func verify(_ settings: CloneEnvironment, in app: URL) throws {
    guard try digest(in: app) == settings.dylibSHA256 else {
      throw CloneFailure("environment_changed", L10n.text(.environmentChanged))
    }
    let descriptor = try AppInspector.inspect(app)
    let original = try Data(
      contentsOf: app.appendingPathComponent("Contents/MacOS/" + descriptor.executable))
    do {
      guard try MachOInjector.insertingDylib(loadPath, into: original) == original else {
        throw CloneFailure("environment_changed", L10n.text(.environmentChanged))
      }
    } catch {
      throw CloneFailure("environment_changed", L10n.text(.environmentChanged))
    }
  }
}
