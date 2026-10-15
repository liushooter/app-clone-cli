import Foundation

@testable import appclonecore

struct AppPlatformTests {
  func run() throws {
    for layout in [
      "flat", "wrapper", "wrapped-link", "mac-layout", "legacy", "universal", "simulator",
    ] {
      try blocksIOSAtSelectionAndBeforeCloneCreatesFiles(layout: layout)
    }
    try metadataRecognizesIOSBeforeStandardMacLayoutValidation()
    for flag in [false, true] {
      try iosCheckCanBeDisabledIndividuallyOrByMasterSwitch(masterSwitch: flag)
      try readsThinAndUniversalPlatformsWithBothByteOrders(bigEndian: flag)
    }
    for platform: UInt32 in [1, 6] {
      try allowsMacAndCatalystEvenWithInheritedIOSMetadata(platform: platform)
    }
    try ignoresUnrelatedWrapperAndPreservesNativeScriptSupport()
    try rejectsTruncatedAndOutOfBoundsMachOHeaders()
  }

  func blocksIOSAtSelectionAndBeforeCloneCreatesFiles(layout: String) throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source.app")
    let bundle: URL
    switch layout {
    case "wrapper": bundle = source.appending(path: "Wrapper/mobile.app")
    case "wrapped-link": bundle = source.appending(path: "payload/mobile.app")
    default: bundle = source
    }
    let binary: Data
    switch layout {
    case "legacy": binary = thin(platform: 2, legacy: true)
    case "universal": binary = fat([thin(platform: 1), thin(platform: 2)])
    case "simulator": binary = thin(platform: 7)
    default: binary = thin(platform: 2)
    }
    // 不依赖 plist 声明；即便包装成 Mac 的 Contents 结构也必须识别实际平台。
    try makeApp(bundle, binary: binary, macLayout: layout == "mac-layout")
    if layout == "wrapped-link" {
      try FileManager.default.createSymbolicLink(
        atPath: source.appending(path: "WrappedBundle").path,
        withDestinationPath: "payload/mobile.app")
    }
    // 同时命中列表与 iOS 平台时，先返回列表错误，不依赖完整的 macOS 布局。
    let blocked = ClonePreflight(
      policy: ClonePolicy(blockedBundleIdentifiers: ["example.platform.fixture"]))
    do {
      _ = try blocked.inspectSource(source).application
      throw CloneFailure("test_failed", "禁止克隆列表应优先拦截")
    } catch let failure as CloneFailure {
      try expect(failure.code == "blocked_application")
    }
    try expectUnsupported { _ = try ClonePreflight().inspectSource(source).application }
    let engine = CloneEngine(
      root: directory.appending(path: "workspace"))
    try expectUnsupported {
      _ = try engine.create(source: source, name: "禁止创建") { event in
        precondition(event.stage == "inspect")
      }
    }
    try expect(!BundleFiles.exists(engine.root))
    try expect(!BundleFiles.exists(engine.root.appending(path: "apps")))
    let executable = bundle.appending(
      path: layout == "mac-layout" ? "Contents/MacOS/fixture" : "fixture")
    try expect(try Data(contentsOf: executable) == binary)
  }

  func metadataRecognizesIOSBeforeStandardMacLayoutValidation() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source.app")
    try makeApp(source, binary: Data("#!/bin/sh\nexit 0\n".utf8), macLayout: false)
    for metadata: [String: Any] in [
      ["CFBundleSupportedPlatforms": ["iPhoneOS"]],
      ["DTPlatformName": "iphoneos"],
      ["LSRequiresIPhoneOS": true],
    ] {
      var plist: [String: Any] = [
        "CFBundleIdentifier": "example.mobile", "CFBundleExecutable": "fixture",
      ]
      plist.merge(metadata) { _, new in new }
      try BundleFiles.writePlist(plist, to: source.appending(path: "Info.plist"))
      try expectUnsupported { _ = try ClonePreflight().inspectSource(source).application }
    }
  }

  func iosCheckCanBeDisabledIndividuallyOrByMasterSwitch(masterSwitch: Bool) throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source.app")
    try makeApp(source, binary: thin(platform: 2), macLayout: true)
    try expectUnsupported { _ = try ClonePreflight().inspectSource(source).application }
    // AppInspector 只读基本信息；平台准入只由 ClonePreflight 决定。
    try expect(try AppInspector.inspect(source).bundleID == "example.platform.fixture")
    let policy =
      masterSwitch ? ClonePolicy(isEnabled: false) : ClonePolicy(checksIOSApplications: false)
    let preflight = ClonePreflight(policy: policy)
    try expect(try preflight.inspectSource(source).application.path == source.path)
    let engine = CloneEngine(
      root: directory.appending(path: "workspace"),
      preflight: preflight)
    let token = CancellationToken()
    do {
      _ = try engine.create(source: source, name: "关闭平台策略", token: token) { event in
        // 验证核心已通过前置检查；模拟二进制不实际复制或签名。
        if event.stage == "copy" { token.cancel() }
      }
      throw CloneFailure("test_failed", "应在复制前取消")
    } catch let failure as CloneFailure {
      try expect(failure.code == "cancelled")
    }
    try expect(try engine.list().isEmpty)
  }

  func allowsMacAndCatalystEvenWithInheritedIOSMetadata(platform: UInt32) throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source.app")
    try makeApp(source, binary: thin(platform: platform), macLayout: true)
    var plist = try BundleFiles.readPlist(BundleFiles.plistURL(source))
    plist["LSRequiresIPhoneOS"] = true
    plist["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
    try BundleFiles.writePlist(plist, to: BundleFiles.plistURL(source))
    // 根目录别名不能让同一份元数据被再次当成未识别平台处理。
    try FileManager.default.createSymbolicLink(
      atPath: source.appending(path: "Info.plist").path, withDestinationPath: "Contents/Info.plist")
    let application = try ClonePreflight().inspectSource(source).application
    try expect(application.bundleID == "example.platform.fixture")
    try expect(application.path == source.path)
  }

  func ignoresUnrelatedWrapperAndPreservesNativeScriptSupport() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source.app")
    try makeApp(source, binary: Data("#!/bin/sh\nexit 0\n".utf8), macLayout: true)
    try FileManager.default.createDirectory(
      at: source.appending(path: "Wrapper/resources"), withIntermediateDirectories: true)
    try expect(
      try ClonePreflight().inspectSource(source).application.bundleID == "example.platform.fixture")
  }

  func readsThinAndUniversalPlatformsWithBothByteOrders(bigEndian: Bool) throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appending(path: "binary")
    for is64 in [false, true] {
      try thin(platform: 2, is64: is64, bigEndian: bigEndian).write(to: executable)
      try expect(try MachOPlatforms.read(executable) == [2])
      try thin(platform: 2, is64: is64, bigEndian: bigEndian, legacy: true).write(to: executable)
      try expect(try MachOPlatforms.read(executable) == [2])
      try fat([thin(platform: 1), thin(platform: 2)], is64: is64, bigEndian: bigEndian).write(
        to: executable)
      try expect(try MachOPlatforms.read(executable) == [1, 2])
    }
  }

  func rejectsTruncatedAndOutOfBoundsMachOHeaders() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appending(path: "binary")
    let invalid = [
      Data(thin(platform: 2).prefix(20)),
      Data(thin(platform: 2).dropLast()),
      words([0xfeed_facf, 0x0100_000c, 0, 2, 1, UInt32.max, 0, 0]),
      words([0xfeed_facf, 0x0100_000c, 0, 2, 1, 8, 0, 0, 0x32, 0]),
      Data(fat([thin(platform: 2)]).dropLast()),
      words([0xcafe_babe, UInt32.max], bigEndian: true),
    ]
    for bytes in invalid {
      try bytes.write(to: executable)
      try expectFailure("invalid_bundle") { _ = try MachOPlatforms.read(executable) }
    }
  }

  private func temporaryDirectory() -> URL {
    BundleFiles.canonical(URL.temporaryDirectory).appending(
      path: "app-clone-platform-tests-\(UUID())")
  }

  private func makeApp(_ app: URL, binary: Data, macLayout: Bool) throws {
    let directory = macLayout ? app.appending(path: "Contents/MacOS") : app
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appending(path: "fixture")
    try binary.write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    try BundleFiles.writePlist(
      [
        "CFBundleIdentifier": "example.platform.fixture", "CFBundleExecutable": "fixture",
        "CFBundleName": "Fixture", "CFBundlePackageType": "APPL",
      ], to: app.appending(path: macLayout ? "Contents/Info.plist" : "Info.plist"))
  }

  private func expectUnsupported(_ body: () throws -> Void) throws {
    do {
      try body()
      throw CloneFailure("test_failed", "iOS 应用必须被明确拒绝")
    } catch let failure as CloneFailure {
      try expect(failure.code == "unsupported_ios_app")
    } catch {
      throw CloneFailure("test_failed", "应返回 iOS 应用不支持错误，实际为：\(error)")
    }
  }

  private func thin(
    platform: UInt32, is64: Bool = true, bigEndian: Bool = false, legacy: Bool = false
  ) -> Data {
    var header: [UInt32] = [
      is64 ? 0xfeed_facf : 0xfeed_face, is64 ? 0x0100_000c : 12, 0, 2, 1, legacy ? 16 : 24, 0,
    ]
    if is64 { header.append(0) }
    let command: [UInt32] =
      legacy ? [platform == 2 ? 0x25 : 0x24, 16, 0, 0] : [0x32, 24, platform, 0, 0, 0]
    return words(header + command, bigEndian: bigEndian)
  }

  private func fat(_ slices: [Data], is64: Bool = false, bigEndian: Bool = true) -> Data {
    var result = words(
      [is64 ? 0xcafe_babf : 0xcafe_babe, UInt32(slices.count)], bigEndian: bigEndian)
    var offset = 8 + slices.count * (is64 ? 32 : 20)
    for slice in slices {
      result.append(words([0x0100_000c, 0], bigEndian: bigEndian))
      if is64 {
        for value in [UInt64(offset), UInt64(slice.count)] {
          result.append(
            contentsOf: (0..<8).map {
              UInt8(truncatingIfNeeded: value >> ((bigEndian ? 7 - $0 : $0) * 8))
            })
        }
        result.append(words([0, 0], bigEndian: bigEndian))
      } else {
        result.append(words([UInt32(offset), UInt32(slice.count), 0], bigEndian: bigEndian))
      }
      offset += slice.count
    }
    for slice in slices { result.append(slice) }
    return result
  }

  private func words(_ values: [UInt32], bigEndian: Bool = false) -> Data {
    Data(
      values.flatMap { value in
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ((bigEndian ? 3 - $0 : $0) * 8)) }
      })
  }
}
