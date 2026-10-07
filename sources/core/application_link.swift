import Foundation

/// An Applications entry is only a symlink; the managed bundle stays in the workspace.
struct ApplicationLink {
  let directory: URL

  func contains(for app: URL) -> Bool {
    do { try BundleFiles.requireRegular(directory, directory: true) } catch { return false }
    return pointsToApp(directory.appendingPathComponent(app.lastPathComponent), app)
  }

  func validateDestination(for app: URL, replacing previous: URL? = nil) throws {
    guard BundleFiles.exists(directory) else { return }
    try BundleFiles.requireRegular(directory, directory: true)
    let link = directory.appendingPathComponent(app.lastPathComponent)
    guard
      !BundleFiles.exists(link) || pointsToApp(link, app)
        || canReplace(link, previous: previous)
    else {
      throw CloneFailure("link_conflict", L10n.text(.linkOccupied, link.path))
    }
  }

  func install(for app: URL, replacing previous: URL? = nil) throws -> URL {
    let fm = FileManager.default
    try validateDestination(for: app, replacing: previous)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    try BundleFiles.requireRegular(directory, directory: true)
    let link = directory.appendingPathComponent(app.lastPathComponent)
    if BundleFiles.exists(link), !pointsToApp(link, app) {
      guard canReplace(link, previous: previous) else {
        throw CloneFailure("link_conflict", L10n.text(.linkOccupied, link.path))
      }
      try fm.removeItem(at: link)
    }
    if !BundleFiles.exists(link) {
      try fm.createSymbolicLink(at: link, withDestinationURL: app)
    }
    if let previous, previous != app { try remove(for: previous) }
    return link
  }

  private func canReplace(_ link: URL, previous: URL?) -> Bool {
    guard let previous,
      link.lastPathComponent.caseInsensitiveCompare(previous.lastPathComponent) == .orderedSame
    else { return false }
    return pointsToApp(link, previous)
  }

  func remove(for app: URL) throws {
    guard BundleFiles.exists(directory) else { return }
    try BundleFiles.requireRegular(directory, directory: true)
    let link = directory.appendingPathComponent(app.lastPathComponent)
    guard pointsToApp(link, app) else { return }
    try FileManager.default.removeItem(at: link)
  }

  private func pointsToApp(_ link: URL, _ app: URL) -> Bool {
    // Compare the stored destination so cleanup works even after the bundle is removed.
    (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == app.path
  }
}
