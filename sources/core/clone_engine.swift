import AppKit
import CryptoKit
import Foundation

public struct CloneEngine: Sendable {
  public let root: URL

  public static var defaultRoot: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/app-clone")
  }

  public static var defaultApplicationsDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/app-clone")
  }

  public static func workspaceRoot(for application: URL) throws -> URL {
    let app = BundleFiles.canonical(application)
    guard app.pathExtension.lowercased() == "app" else {
      throw CloneFailure("not_app", L10n.text(.clonePathRequired))
    }
    let directory = app.deletingLastPathComponent()
    let root = directory.deletingLastPathComponent()
    let catalog = root.appendingPathComponent("state.json")
    guard directory.lastPathComponent == "apps", BundleFiles.exists(catalog) else {
      throw CloneFailure(
        "not_managed", L10n.text(.workspaceNotManaged, app.path))
    }
    try BundleFiles.requireRegular(catalog)
    return root
  }

  public func registerApplications() throws -> [RegistrationResult] {
    let workspace = Workspace(root: root)
    return try workspace.withLock {
      try workspace.readCatalog().clones.map { record in
        let app = try workspace.appURL(record)
        try BundleFiles.checkOwnership(app, record: record)
        let link = try ApplicationLink(directory: Self.defaultApplicationsDirectory).install(
          for: app)
        return RegistrationResult(
          name: record.name, path: link.path,
          status: AppRegistration.refresh(link))
      }
    }
  }

  public init(root: URL = Self.defaultRoot) {
    self.root = BundleFiles.canonical(root)
  }

  public func list() throws -> [CloneRecord] {
    let workspace = Workspace(root: root)
    return try workspace.withLock { try workspace.readCatalog().clones }
  }

  public func statistics() throws -> [CloneStatistics] {
    let workspace = Workspace(root: root)
    return try workspace.withLock {
      let catalog = try workspace.readCatalog().trackingCreations()
      let groups = Dictionary(grouping: catalog.clones, by: { $0.source.bundleID })
      return (catalog.creationCounts ?? [:]).sorted { $0.key < $1.key }.map { bundleID, counter in
        CloneStatistics(
          sourceBundleID: bundleID, sourceName: counter.name,
          totalCreated: counter.totalCreated, currentCount: groups[bundleID]?.count ?? 0,
          historyComplete: catalog.historyComplete == true)
      }
    }
  }

  public func create(
    source: URL, name: String, icon: URL? = nil,
    token: CancellationToken = CancellationToken(),
    onEvent: EventHandler = { _ in }
  ) throws -> CloneRecord {
    try token.check()
    let name = try validatedName(name)
    onEvent(CloneEvent("inspect", L10n.text(.inspectProgress)))
    let descriptor = try AppInspector.inspect(source)
    if try BundleFiles.isSystemApplication(
      URL(fileURLWithPath: descriptor.path), executable: descriptor.executable)
    {
      throw CloneFailure(
        "unsupported_system_app", L10n.text(.unsupportedSystemApp, descriptor.path))
    }
    try validateSourceLocation(URL(fileURLWithPath: descriptor.path))
    let workspace = Workspace(root: root)
    return try workspace.withLock {
      let before = try workspace.readCatalog()
      try ensureNameAvailable(name, in: before)
      let id = UUID().uuidString.lowercased()
      let created =
        before.trackingCreations().creationCounts?[descriptor.bundleID]?.totalCreated ?? 0
      guard created < Int.max else {
        throw CloneFailure("clone_count_exhausted", L10n.text(.cloneCountExhausted))
      }
      let number = created + 1
      let bundleID = "\(descriptor.bundleID).\(number).\(id)"
      guard bundleID.utf8.count <= 255 else {
        throw CloneFailure("invalid_bundle_id", L10n.text(.bundleIDTooLong))
      }
      try BundleFiles.validateBundleID(bundleID)
      let record = CloneRecord(
        id: id, name: name,
        bundleID: bundleID,
        appFileName: try workspace.availableAppFileName(name: name, id: id, catalog: before),
        cloneNumber: number,
        source: descriptor, createdAt: Date(), modifiedAt: Date(),
        customIconSHA256: nil, compatibility: "unverified")
      return try build(
        record: record, from: URL(fileURLWithPath: descriptor.path), icon: icon,
        workspace: workspace, before: before,
        token: token, onEvent: onEvent)
    }
  }

  public func replaceIcon(
    app application: URL, icon: URL, token: CancellationToken = CancellationToken(),
    onEvent: EventHandler = { _ in }
  ) throws -> CloneRecord {
    let workspace = Workspace(root: root)
    return try workspace.withLock {
      let before = try workspace.readCatalog()
      let record = try find(application, in: before)
      let app = try workspace.appURL(record)
      try BundleFiles.checkOwnership(app, record: record)
      try ensureStopped(app)
      return try build(
        record: record, from: app, icon: icon,
        workspace: workspace, before: before, token: token, onEvent: onEvent)
    }
  }

  /// With no options this only reads the managed clone's environment configuration.
  public func configureEnvironment(
    app application: URL, dataDirectory: URL? = nil, proxy: String? = nil, locale: String? = nil,
    appLanguage: String? = nil, reset: Bool = false, token: CancellationToken = CancellationToken(),
    onEvent: EventHandler = { _ in }
  ) throws -> CloneRecord {
    try token.check()
    let workspace = Workspace(root: root)
    return try workspace.withLock {
      let before = try workspace.readCatalog()
      var record = try find(application, in: before)
      let app = try workspace.appURL(record)
      try BundleFiles.checkOwnership(app, record: record)
      guard reset || dataDirectory != nil || proxy != nil || locale != nil || appLanguage != nil
      else {
        return record
      }
      guard !reset || (dataDirectory == nil && proxy == nil && locale == nil && appLanguage == nil)
      else {
        throw CloneFailure("usage", L10n.text(.resetEnvironmentUsage))
      }
      try ensureStopped(app)
      if reset {
        guard record.environment != nil else { return record }
        record.environment = nil
      } else {
        var settings = record.environment ?? CloneEnvironment()
        if let dataDirectory { settings.dataDirectory = BundleFiles.canonical(dataDirectory).path }
        if let proxy { settings.proxy = proxy }
        if let locale { settings.locale = locale }
        if let appLanguage { settings.appLanguage = appLanguage }
        try EnvironmentInstaller.validate(
          settings, workspace: root, source: URL(fileURLWithPath: record.source.path))
        record.environment = settings
      }
      return try build(
        record: record, from: app, icon: nil, workspace: workspace, before: before,
        token: token, onEvent: onEvent, updateEnvironment: true)
    }
  }

  public func rename(
    app application: URL, name: String, token: CancellationToken = CancellationToken(),
    onEvent: EventHandler = { _ in }
  ) throws -> CloneRecord {
    try token.check()
    let name = try validatedName(name)
    let workspace = Workspace(root: root)
    return try workspace.withLock {
      let before = try workspace.readCatalog()
      let original = try find(application, in: before)
      let app = try workspace.appURL(original)
      try BundleFiles.checkOwnership(app, record: original)
      try ensureNameAvailable(name, in: before, excluding: original.id)
      if name == original.name, original.appFileName != nil { return original }
      try ensureStopped(app)
      var record = original
      record.name = name
      record.appFileName = try workspace.availableAppFileName(
        name: name, id: original.id, catalog: before, replacing: original)
      let links = ApplicationLink(directory: Self.defaultApplicationsDirectory)
      if root == BundleFiles.canonical(Self.defaultRoot) || links.contains(for: app) {
        try links.validateDestination(for: workspace.appURL(record), replacing: app)
      }
      onEvent(CloneEvent("rename", L10n.text(.renameProgress)))
      return try build(
        record: record, from: app, icon: nil,
        workspace: workspace, before: before, token: token, onEvent: onEvent)
    }
  }

  public func remove(
    app application: URL, token: CancellationToken = CancellationToken(),
    onEvent: EventHandler = { _ in }
  ) throws -> CloneRecord {
    let workspace = Workspace(root: root)
    return try workspace.withLock {
      try token.check()
      let before = try workspace.readCatalog()
      let record = try find(application, in: before)
      let app = try workspace.appURL(record)
      try BundleFiles.checkOwnership(app, record: record)
      try ensureStopped(app)
      let operationID = UUID().uuidString.lowercased()
      let job = try workspace.jobURL(operationID)
      try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false)
      defer {
        if !BundleFiles.exists(workspace.journalURL) {
          try? FileManager.default.removeItem(at: job)
        }
      }
      var after = before.trackingCreations()
      after.clones.removeAll { $0.id == record.id }
      after.revision = UUID().uuidString.lowercased()
      try token.check()
      onEvent(CloneEvent("remove", L10n.text(.removeProgress)))
      try workspace.commit(
        cloneID: record.id, operationID: operationID, before: before, after: after)
      if root == BundleFiles.canonical(Self.defaultRoot) {
        do {
          try ApplicationLink(directory: Self.defaultApplicationsDirectory).remove(for: app)
        } catch {
          onEvent(
            CloneEvent(
              "link_warning",
              L10n.text(.linkCleanupWarning, error.localizedDescription)))
        }
      }
      onEvent(CloneEvent("complete", L10n.text(.removedProgress)))
      return record
    }
  }

  public func verify(app application: URL, token: CancellationToken = CancellationToken()) throws
    -> CloneRecord
  {
    let workspace = Workspace(root: root)
    return try workspace.withLock {
      let record = try find(application, in: workspace.readCatalog())
      let app = try workspace.appURL(record)
      try BundleFiles.checkOwnership(app, record: record)
      try verifySignature(app, token: token)
      if record.customIconSHA256 != nil { _ = try preservedIcon(record, at: app) }
      if let settings = record.environment { try EnvironmentInstaller.verify(settings, in: app) }
      return record
    }
  }

  private func build(
    record original: CloneRecord, from source: URL, icon: URL?,
    workspace: Workspace, before: Catalog, token: CancellationToken,
    onEvent: EventHandler, updateEnvironment: Bool = false
  ) throws -> CloneRecord {
    try token.check()
    let fm = FileManager.default
    let operationID = UUID().uuidString.lowercased()
    let job = try workspace.jobURL(operationID)
    try fm.createDirectory(at: job, withIntermediateDirectories: false)
    defer { if !BundleFiles.exists(workspace.journalURL) { try? fm.removeItem(at: job) } }
    var record = original
    let prepared: PreparedIcon?
    if let icon {
      onEvent(CloneEvent("icon", L10n.text(.iconProgress)))
      prepared = try IconBuilder().prepare(icon, token: token)
    } else {
      prepared = nil
    }
    try BundleFiles.validateLinks(in: source, token: token)
    let candidate = job.appendingPathComponent("candidate.app")
    onEvent(CloneEvent("copy", L10n.text(.copyProgress)))
    _ = try ProcessRunner().run("/usr/bin/ditto", [source.path, candidate.path], token: token)
    try BundleFiles.validateLinks(in: candidate, token: token)
    _ = try AppInspector.inspect(candidate)
    if let settings = before.clones.first(where: { $0.id == record.id })?.environment {
      try EnvironmentInstaller.verify(settings, in: candidate)
    }
    onEvent(CloneEvent("identity", L10n.text(.identityProgress)))
    var plist = try BundleFiles.readPlist(BundleFiles.plistURL(candidate))
    plist["CFBundleIdentifier"] = record.bundleID
    plist["CFBundleName"] = record.name
    plist["CFBundleDisplayName"] = record.name
    plist[BundleFiles.ownershipKey] = record.id
    plist.removeValue(forKey: "LSHasLocalizedDisplayName")
    try BundleFiles.writePlist(plist, to: BundleFiles.plistURL(candidate))
    try removeLocalizedNames(in: candidate)
    if let prepared {
      try IconBuilder().install(prepared, into: candidate)
      record.customIconSHA256 = prepared.sha256
    }
    if updateEnvironment {
      onEvent(CloneEvent("environment", L10n.text(.environmentProgress)))
      try EnvironmentInstaller.install(
        record.environment,
        replacing: before.clones.first(where: { $0.id == record.id })?.environment,
        into: candidate, job: job, token: token)
    }
    try token.check()
    onEvent(CloneEvent("attributes", L10n.text(.attributesProgress)))
    _ = try ProcessRunner().run("/usr/bin/xattr", ["-crs", candidate.path], token: token)
    onEvent(CloneEvent("sign", L10n.text(.signProgress)))
    _ = try ProcessRunner().run(
      "/usr/bin/codesign", ["--force", "--deep", "--sign", "-", candidate.path], token: token)
    onEvent(CloneEvent("verify", L10n.text(.verifyProgress)))
    try verifySignature(candidate, token: token)
    if record.customIconSHA256 != nil { _ = try preservedIcon(record, at: candidate) }
    if record.environment != nil {
      record.environment?.dylibSHA256 = try EnvironmentInstaller.digest(in: candidate)
    }
    record.modifiedAt = Date()
    var after = before.trackingCreations()
    if !before.clones.contains(where: { $0.id == record.id }) {
      guard let number = record.cloneNumber else {
        throw CloneFailure("invalid_state", L10n.text(.creationNumberMissing))
      }
      after.creationCounts?[record.source.bundleID] = CloneCounter(
        name: record.source.name, totalCreated: number)
    }
    after.clones.removeAll { $0.id == record.id }
    after.clones.append(record)
    after.revision = UUID().uuidString.lowercased()
    try token.check()
    let target = try workspace.appURL(record)
    let previous = try before.clones.first { $0.id == record.id }.map { try workspace.appURL($0) }
    if let previous { try ensureStopped(previous) }
    if updateEnvironment, let settings = record.environment {
      try EnvironmentInstaller.prepareDirectories(settings)
      try token.check()
    }
    onEvent(CloneEvent("install", L10n.text(.installProgress)))
    try workspace.commit(cloneID: record.id, operationID: operationID, before: before, after: after)
    let links = ApplicationLink(directory: Self.defaultApplicationsDirectory)
    if root == BundleFiles.canonical(Self.defaultRoot)
      || previous.map({ links.contains(for: $0) }) == true
    {
      publish(target, replacing: previous, onEvent: onEvent)
    }
    onEvent(CloneEvent("complete", L10n.text(.savedProgress)))
    return record
  }

  private func publish(_ app: URL, replacing previous: URL? = nil, onEvent: EventHandler) {
    let links = ApplicationLink(directory: Self.defaultApplicationsDirectory)
    do {
      let link = try links.install(for: app, replacing: previous)
      AppRegistration.refresh(link, onEvent: onEvent)
    } catch {
      onEvent(
        CloneEvent(
          "link_warning",
          L10n.text(.linkUpdateWarning, error.localizedDescription)))
    }
  }

  private func preservedIcon(_ record: CloneRecord, at app: URL) throws -> PreparedIcon {
    let resources = app.appendingPathComponent("Contents/Resources")
    try BundleFiles.requireRegular(resources, directory: true)
    let path = resources.appendingPathComponent(BundleFiles.customIcon)
    try BundleFiles.requireRegular(path)
    let data = try Data(contentsOf: path)
    try IconBuilder().validateICNS(data)
    let icon = PreparedIcon(data: data)
    guard icon.sha256 == record.customIconSHA256 else {
      throw CloneFailure("icon_changed", L10n.text(.iconChanged))
    }
    return icon
  }

  private func removeLocalizedNames(in app: URL) throws {
    let resources = app.appendingPathComponent("Contents/Resources")
    guard BundleFiles.exists(resources) else { return }
    try BundleFiles.requireRegular(resources, directory: true)
    for directory in try FileManager.default.contentsOfDirectory(
      at: resources, includingPropertiesForKeys: nil)
    where directory.pathExtension == "lproj" {
      let path = directory.appendingPathComponent("InfoPlist.strings")
      if BundleFiles.exists(path) {
        try BundleFiles.requireRegular(directory, directory: true)
        var plist = try BundleFiles.readPlist(path)
        for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleGetInfoString"] {
          plist.removeValue(forKey: key)
        }
        try BundleFiles.writePlist(plist, to: path)
      }
    }
  }

  private func verifySignature(_ app: URL, token: CancellationToken) throws {
    _ = try ProcessRunner().run(
      "/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", app.path], token: token
    )
  }

  private func validateSourceLocation(_ source: URL) throws {
    let apps = Workspace(root: root).apps
    guard source != root, !BundleFiles.isWithin(root, source), !BundleFiles.isWithin(source, root),
      source != apps, !BundleFiles.isWithin(apps, source), !BundleFiles.isWithin(source, apps)
    else {
      throw CloneFailure("overlapping_paths", L10n.text(.overlappingPaths))
    }
  }

  private func validatedName(_ name: String) throws -> String {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 80,
      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw CloneFailure("invalid_name", L10n.text(.invalidName))
    }
    return name
  }

  private func ensureNameAvailable(_ name: String, in catalog: Catalog, excluding id: String? = nil)
    throws
  {
    guard
      !catalog.clones.contains(where: {
        $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
      })
    else {
      throw CloneFailure("name_conflict", L10n.text(.nameConflict, name))
    }
  }

  private func find(_ application: URL, in catalog: Catalog) throws -> CloneRecord {
    let app = BundleFiles.canonical(application)
    let workspace = Workspace(root: root)
    for record in catalog.clones {
      if try BundleFiles.canonical(workspace.appURL(record)) == app { return record }
    }
    throw CloneFailure("not_managed", L10n.text(.notManaged, app.path))
  }

  private func ensureStopped(_ app: URL) throws {
    let path = BundleFiles.canonical(app).path
    if NSWorkspace.shared.runningApplications.contains(where: {
      guard let bundle = $0.bundleURL else { return false }
      return BundleFiles.canonical(bundle).path == path || BundleFiles.isWithin(bundle, app)
    }) {
      throw CloneFailure("app_running", L10n.text(.appRunning))
    }
  }
}
