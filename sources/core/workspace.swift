import Darwin
import Foundation

private struct Journal: Codable {
  let operationID: String
  let cloneID: String
  let before: Catalog
  let after: Catalog
  var relocation: Bool? = nil
}

struct Workspace {
  let root: URL
  var apps: URL { root.appendingPathComponent("apps") }
  var staging: URL { root.appendingPathComponent("staging") }
  var catalogURL: URL { root.appendingPathComponent("state.json") }
  var journalURL: URL { root.appendingPathComponent("pending.json") }

  init(root: URL) {
    self.root = BundleFiles.canonical(root)
  }

  func appURL(_ record: CloneRecord) throws -> URL {
    try BundleFiles.validateID(record.id)
    let filename = record.appFileName ?? record.id + ".app"
    guard filename.hasSuffix(".app"), filename.utf8.count <= 255,
      !filename.hasPrefix("."), !filename.contains("/"), !filename.contains(":"),
      !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw CloneFailure("invalid_app_filename", L10n.text(.invalidAppFilename))
    }
    return apps.appendingPathComponent(filename)
  }

  func availableAppFileName(
    name: String, id: String, catalog: Catalog, replacing: CloneRecord? = nil
  ) throws -> String {
    try BundleFiles.validateID(id)
    let cleaned = name.precomposedStringWithCanonicalMapping
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    var base = ""
    for character in cleaned {
      let next = base + String(character)
      if next.utf8.count > 200 { break }
      base = next
    }
    if base.isEmpty { base = "分身" }
    let current = try replacing.map { try appURL($0) }
    let reserved = try catalog.clones.filter { $0.id != replacing?.id }
      .map { try appURL($0).lastPathComponent }
    for suffix in ["", " (\(id.prefix(8)))", " (\(id))"] {
      let filename = base + suffix + ".app"
      let candidate = apps.appendingPathComponent(filename)
      if !reserved.contains(where: { $0.caseInsensitiveCompare(filename) == .orderedSame }),
        !BundleFiles.exists(candidate)
          || current.map({ BundleFiles.sameItem($0, candidate) }) == true
      {
        return filename
      }
    }
    throw CloneFailure("destination_exists", L10n.text(.noAvailableFilename))
  }

  func jobURL(_ id: String) throws -> URL {
    try BundleFiles.validateID(id)
    return staging.appendingPathComponent(id)
  }

  private func prepare() throws {
    for directory in [root, apps, staging] {
      if !BundleFiles.exists(directory) {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      }
      try BundleFiles.requireRegular(directory, directory: true)
    }
  }

  func withLock<T>(_ action: () throws -> T) throws -> T {
    try prepare()
    let lockURL = root.appendingPathComponent("workspace.lock")
    let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw CloneFailure("lock_failed", L10n.text(.lockFailed, root.path))
    }
    defer { Darwin.close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      throw CloneFailure("workspace_busy", L10n.text(.workspaceBusy))
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    try recover()
    return try action()
  }

  func readCatalog() throws -> Catalog {
    guard BundleFiles.exists(catalogURL) else { return Catalog(revision: "initial") }
    try BundleFiles.requireRegular(catalogURL)
    do {
      let catalog = try JSONCoding.decode(Catalog.self, from: Data(contentsOf: catalogURL))
      try validate(catalog)
      return catalog
    } catch {
      throw CloneFailure(
        "invalid_state", L10n.text(.stateUnreadable, error.localizedDescription)
      )
    }
  }

  private func validate(_ catalog: Catalog) throws {
    guard [1, 2, 3].contains(catalog.schemaVersion),
      Set(catalog.clones.map(\.id)).count == catalog.clones.count
    else {
      throw CloneFailure("invalid_state", L10n.text(.stateVersion))
    }
    var filenames: [String] = []
    for record in catalog.clones {
      try BundleFiles.validateID(record.id)
      try BundleFiles.validateBundleID(record.bundleID)
      try BundleFiles.validateBundleID(record.source.bundleID)
      if let number = record.cloneNumber {
        guard number > 0,
          record.bundleID == "\(record.source.bundleID).\(number).\(record.id)"
        else {
          throw CloneFailure("invalid_state", L10n.text(.stateNumber))
        }
      }
      let filename = try appURL(record).lastPathComponent
      guard !filenames.contains(where: { $0.caseInsensitiveCompare(filename) == .orderedSame })
      else {
        throw CloneFailure("invalid_state", L10n.text(.stateFilename))
      }
      filenames.append(filename)
    }
    if catalog.schemaVersion == 3,
      catalog.creationCounts == nil || catalog.historyComplete == nil
    {
      throw CloneFailure("invalid_state", L10n.text(.stateCountsMissing))
    }
    if let counts = catalog.creationCounts {
      for (bundleID, counter) in counts {
        try BundleFiles.validateBundleID(bundleID)
        guard counter.totalCreated >= 0 else {
          throw CloneFailure("invalid_state", L10n.text(.stateCountsNegative))
        }
      }
      for (bundleID, records) in Dictionary(grouping: catalog.clones, by: { $0.source.bundleID }) {
        let numbers = records.compactMap(\.cloneNumber)
        guard let counter = counts[bundleID], counter.totalCreated >= records.count,
          counter.totalCreated >= (numbers.max() ?? 0), Set(numbers).count == numbers.count
        else {
          throw CloneFailure("invalid_state", L10n.text(.stateCountsMismatch))
        }
      }
    }
  }

  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    if BundleFiles.exists(url) { try BundleFiles.requireRegular(url) }
    try JSONCoding.encode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.synchronize()
  }

  /// The prepared bundle and backup live on the same volume as the installation.
  /// Cancellation is deferred during this short, journaled commit section.
  func commit(
    cloneID: String, operationID: String, before: Catalog, after: Catalog
  ) throws {
    let fm = FileManager.default
    let job = try jobURL(operationID)
    let candidate = job.appendingPathComponent("candidate.app")
    let backup = job.appendingPathComponent("previous.app")
    let old = before.clones.first { $0.id == cloneID }
    let new = after.clones.first { $0.id == cloneID }
    guard let record = old ?? new else {
      throw CloneFailure("invalid_journal", L10n.text(.journalRecordMissing))
    }
    let target = try appURL(record)
    let destination = try new.map { try appURL($0) } ?? target
    if let old {
      try BundleFiles.checkOwnership(target, record: old)
    } else if BundleFiles.exists(target) {
      throw CloneFailure(
        "destination_exists", L10n.text(.targetExists, target.path))
    }
    if target != destination {
      guard !BundleFiles.exists(destination) || BundleFiles.sameItem(target, destination) else {
        throw CloneFailure(
          "destination_exists", L10n.text(.destinationExists, destination.path))
      }
    }
    if let new {
      try BundleFiles.checkOwnership(candidate, record: new)
    }
    try write(
      Journal(
        operationID: operationID, cloneID: cloneID, before: before, after: after),
      to: journalURL)
    do {
      if old != nil { try fm.moveItem(at: target, to: backup) }
      if new != nil { try fm.moveItem(at: candidate, to: destination) }
      try write(after, to: catalogURL)
    } catch {
      do { try recover() } catch {
        throw CloneFailure(
          "recovery_required",
          L10n.text(.recoveryRequired, error.localizedDescription))
      }
      throw error
    }
    try fm.removeItem(at: journalURL)
    try? fm.removeItem(at: job)
  }

  private func recover() throws {
    guard BundleFiles.exists(journalURL) else { return }
    try BundleFiles.requireRegular(journalURL)
    let journal: Journal
    do {
      journal = try JSONCoding.decode(Journal.self, from: Data(contentsOf: journalURL))
      try validate(journal.before)
      try validate(journal.after)
    } catch {
      throw CloneFailure(
        "invalid_journal",
        L10n.text(.journalUnreadable, error.localizedDescription))
    }
    let current = try readCatalog()
    guard current.revision == journal.before.revision || current.revision == journal.after.revision
    else {
      throw CloneFailure("recovery_conflict", L10n.text(.recoveryRevision))
    }
    let fm = FileManager.default
    let job = try jobURL(journal.operationID)
    try BundleFiles.requireRegular(job, directory: true)
    let backup = job.appendingPathComponent("previous.app")
    let old = journal.before.clones.first { $0.id == journal.cloneID }
    let new = journal.after.clones.first { $0.id == journal.cloneID }
    if journal.relocation == true {
      try recoverRelocation(
        old: old, new: new, committed: current.revision == journal.after.revision)
      if current.revision == journal.before.revision { try write(journal.before, to: catalogURL) }
      try fm.removeItem(at: journalURL)
      try? fm.removeItem(at: job)
      return
    }
    guard let record = old ?? new else {
      throw CloneFailure("invalid_journal", L10n.text(.journalIdentityMissing))
    }
    let target = try appURL(record)
    let destination = try new.map { try appURL($0) } ?? target
    if current.revision == journal.after.revision {
      if let new {
        try BundleFiles.checkOwnership(destination, record: new)
        if target != destination, BundleFiles.exists(target),
          !BundleFiles.sameItem(target, destination)
        {
          throw CloneFailure("recovery_conflict", L10n.text(.recoveryRenamedPath))
        }
      } else if BundleFiles.exists(target) {
        throw CloneFailure("recovery_conflict", L10n.text(.recoveryRemovedPath))
      }
    } else {
      if let old {
        if BundleFiles.exists(backup) {
          try BundleFiles.checkOwnership(backup, record: old)
          if target != destination, BundleFiles.exists(target),
            !BundleFiles.sameItem(target, destination)
          {
            throw CloneFailure("recovery_conflict", L10n.text(.recoveryOriginalOccupied))
          }
          if BundleFiles.exists(destination) {
            guard let new else {
              throw CloneFailure("recovery_conflict", L10n.text(.recoveryTargetOccupied))
            }
            try BundleFiles.checkOwnership(destination, record: new)
            try fm.removeItem(at: destination)
          }
          try fm.moveItem(at: backup, to: target)
        } else {
          try BundleFiles.checkOwnership(target, record: old)
          if target != destination, BundleFiles.exists(destination),
            !BundleFiles.sameItem(target, destination)
          {
            throw CloneFailure("recovery_conflict", L10n.text(.recoveryRenameOccupied))
          }
        }
      } else if BundleFiles.exists(target) {
        guard let new else {
          throw CloneFailure("invalid_journal", L10n.text(.journalTargetMissing))
        }
        try BundleFiles.checkOwnership(target, record: new)
        try fm.removeItem(at: target)
      }
      try write(journal.before, to: catalogURL)
    }
    try fm.removeItem(at: journalURL)
    try? fm.removeItem(at: job)
  }

  private func recoverRelocation(old: CloneRecord?, new: CloneRecord?, committed: Bool) throws {
    guard let old, let new, old.id == new.id, old.bundleID == new.bundleID else {
      throw CloneFailure("invalid_journal", L10n.text(.journalRenameIdentity))
    }
    let source = try appURL(old)
    let destination = try appURL(new)
    guard source != destination else {
      throw CloneFailure("invalid_journal", L10n.text(.journalSamePath))
    }
    if committed {
      try BundleFiles.checkOwnership(destination, record: new)
      guard !BundleFiles.exists(source) else {
        throw CloneFailure("recovery_conflict", L10n.text(.recoveryOldPath))
      }
    } else if BundleFiles.exists(source) {
      try BundleFiles.checkOwnership(source, record: old)
      guard !BundleFiles.exists(destination) else {
        throw CloneFailure("recovery_conflict", L10n.text(.recoveryRenameOccupied))
      }
    } else {
      try BundleFiles.checkOwnership(destination, record: new)
      try FileManager.default.moveItem(at: destination, to: source)
    }
  }
}
