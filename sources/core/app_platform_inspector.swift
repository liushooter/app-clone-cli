import Foundation
import MachO

enum AppPlatformInspector {
  struct Metadata {
    let plist: [String: Any]
    let executableDirectory: URL
  }

  /// 只读取安装包装与 plist，供低成本的列表检查先使用，不读取可执行文件。
  static func metadata(in app: URL, inspect: (Metadata) throws -> Void) throws -> [Metadata] {
    var bundles = [app]
    let wrapped = app.appending(path: "WrappedBundle")
    if BundleFiles.exists(wrapped), BundleFiles.isWithin(wrapped, app) {
      bundles.append(BundleFiles.canonical(wrapped))
    }
    let wrapper = app.appending(path: "Wrapper")
    if BundleFiles.exists(wrapper), BundleFiles.isWithin(wrapper, app),
      try wrapper.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    {
      bundles += try FileManager.default.contentsOfDirectory(
        at: wrapper, includingPropertiesForKeys: nil
      ).filter { $0.pathExtension.lowercased() == "app" && BundleFiles.isWithin($0, app) }
    }
    var visited: Set<URL> = []
    var inspectedPlists: Set<URL> = []
    var result: [Metadata] = []
    for bundle in bundles {
      let bundle = BundleFiles.canonical(bundle)
      guard visited.insert(bundle).inserted else { continue }
      for relative in ["Contents/Info.plist", "Info.plist"] {
        let info = BundleFiles.canonical(bundle.appending(path: relative))
        guard BundleFiles.isWithin(info, app), BundleFiles.exists(info),
          inspectedPlists.insert(info).inserted
        else { continue }
        let plist = try BundleFiles.readPlist(info)
        let executableDirectory =
          relative == "Info.plist" ? bundle : bundle.appending(path: "Contents/MacOS")
        let entry = Metadata(plist: plist, executableDirectory: executableDirectory)
        try inspect(entry)
        result.append(entry)
      }
    }
    return result
  }

  static func isIOSApplication(_ app: URL, metadata: [Metadata]) throws -> Bool {
    for entry in metadata {
      let plist = entry.plist
      let platforms = try executablePlatforms(plist, directory: entry.executableDirectory, app: app)
      if platforms.contains(UInt32(PLATFORM_IOS))
        || platforms.contains(UInt32(PLATFORM_IOSSIMULATOR))
      {
        return true
      }
      // Catalyst 可能沿用 iOS 的 plist 字段；实际构建平台优先，避免误拦。
      if platforms.contains(UInt32(PLATFORM_MACOS))
        || platforms.contains(UInt32(PLATFORM_MACCATALYST))
      {
        continue
      }
      let supported = (plist["CFBundleSupportedPlatforms"] as? [String] ?? []).map {
        $0.lowercased()
      }
      let platformName = (plist["DTPlatformName"] as? String)?.lowercased()
      if supported.contains("iphoneos") || supported.contains("iphonesimulator")
        || platformName == "iphoneos" || platformName == "iphonesimulator"
      {
        return true
      }
      if !supported.contains("macosx"), platformName != "macosx",
        plist["LSRequiresIPhoneOS"] as? Bool == true
      {
        return true
      }
    }
    return false
  }

  private static func executablePlatforms(_ plist: [String: Any], directory: URL, app: URL) throws
    -> Set<UInt32>
  {
    guard let name = plist["CFBundleExecutable"] as? String, !name.isEmpty,
      name != ".", name != "..", !name.contains("/"), !name.contains("\0")
    else { return [] }
    let executable = BundleFiles.canonical(directory.appending(path: name))
    guard BundleFiles.isWithin(executable, app), BundleFiles.exists(executable) else { return [] }
    try BundleFiles.requireRegular(executable)
    return try MachOPlatforms.read(executable)
  }

}
