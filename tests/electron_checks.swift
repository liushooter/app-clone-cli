import Foundation

@testable import appclonecore

struct ElectronInspectorTests {
  func run() throws {
    for offset in [128, 1024 * 1024 - 16, 1024 * 1024 - 33, 1024 * 1024 - 35] {
      try recognizesRenamedFrameworkAcrossReadBoundaries(offset: offset)
    }
    try standardFrameworkSupportsOlderRuntimeWithoutFuses()
    try rejectsTextTruncatedAndInvalidFuseRecords()
    try ignoresInvalidMarkerBeforeValidWireAndRecognizesUniversalBinary()
    try ignoresResourceMarkersAndDoesNotFollowExternalRuntimeLinks()
    try cancellationIsNotTreatedAsNonElectron()
  }

  private let sentinel = Data("dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX".utf8)
  private let magic = Data([0xcf, 0xfa, 0xed, 0xfe])

  func recognizesRenamedFrameworkAcrossReadBoundaries(offset: Int) throws {
    var binary = magic
    binary.append(Data(repeating: 0, count: offset - binary.count))
    binary.append(sentinel + Data([1, 3]) + Data("01r".utf8))
    try withFramework(binary: binary) { app in
      let detected = try ElectronInspector.isElectron(app, token: CancellationToken())
      try expect(detected)
    }
  }

  func standardFrameworkSupportsOlderRuntimeWithoutFuses() throws {
    try withFramework(name: "Electron Framework", binary: magic + Data(repeating: 0, count: 64)) {
      app in
      let detected = try ElectronInspector.isElectron(app, token: CancellationToken())
      try expect(detected)
    }
  }

  func rejectsTextTruncatedAndInvalidFuseRecords() throws {
    let samples = [
      sentinel + Data([1, 1, 0x31]),
      magic + sentinel,
      magic + sentinel + Data([1]),
      magic + sentinel + Data([1, 0]),
      magic + sentinel + Data([1, 3, 0x31]),
      magic + sentinel + Data([2, 1, 0x31]),
      magic + sentinel + Data([1, 1, 0x32]),
      magic + Data("ordinary native framework".utf8),
    ]
    for binary in samples {
      try withFramework(binary: binary) { app in
        let detected = try ElectronInspector.isElectron(app, token: CancellationToken())
        try expect(!detected)
      }
    }
    try withFramework(name: "Electron Framework", binary: Data("not a binary".utf8)) { app in
      let detected = try ElectronInspector.isElectron(app, token: CancellationToken())
      try expect(!detected)
    }
  }

  func ignoresInvalidMarkerBeforeValidWireAndRecognizesUniversalBinary() throws {
    let binary =
      Data([0xca, 0xfe, 0xba, 0xbe]) + sentinel + Data([1, 1, 0x32])
      + Data(repeating: 0, count: 100) + sentinel + Data([1, 2, 0x30, 0x31])
    try withFramework(binary: binary) { app in
      let detected = try ElectronInspector.isElectron(app, token: CancellationToken())
      try expect(detected)
    }
  }

  func ignoresResourceMarkersAndDoesNotFollowExternalRuntimeLinks() throws {
    try withFramework(binary: magic + Data(repeating: 0, count: 64)) { app in
      let contents = app.appending(path: "Contents")
      let resources = contents.appending(path: "Resources")
      try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
      let external = app.deletingLastPathComponent().appending(path: "external")
      let marker = magic + sentinel + Data([1, 1, 0x31])
      try marker.write(to: resources.appending(path: "app.asar"))
      try marker.write(to: external)
      try expect(try !ElectronInspector.isElectron(app, token: CancellationToken()))
      let runtime = contents.appending(path: "Frameworks/renamed.framework/runtime")
      try FileManager.default.removeItem(at: runtime)
      try FileManager.default.createSymbolicLink(at: runtime, withDestinationURL: external)
      try expect(try !ElectronInspector.isElectron(app, token: CancellationToken()))
    }
  }

  func cancellationIsNotTreatedAsNonElectron() throws {
    try withFramework(binary: magic + sentinel + Data([1, 1, 0x31])) { app in
      let token = CancellationToken()
      token.cancel()
      do {
        _ = try ElectronInspector.isElectron(app, token: token)
        throw CloneFailure("test_failed", "取消必须中断检测")
      } catch let error as CloneFailure {
        try expect(error.code == "cancelled")
      }
    }
  }

  private func withFramework(
    name: String = "renamed", binary: Data, body: (URL) throws -> Void
  ) throws {
    let directory = BundleFiles.canonical(URL.temporaryDirectory).appending(
      path: "app-clone-electron-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = directory.appending(path: "source.app")
    let framework = app.appending(path: "Contents/Frameworks/\(name).framework")
    let resources = framework.appending(path: "Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try BundleFiles.writePlist(
      ["CFBundleExecutable": "runtime", "CFBundlePackageType": "FMWK"],
      to: resources.appending(path: "Info.plist"))
    try binary.write(to: framework.appending(path: "runtime"))
    try body(app)
  }
}
