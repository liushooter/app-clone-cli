import Foundation

/// 只检查应用直属 Framework 的运行时，不加载代码或修改 Electron 开关。
enum ElectronInspector {
  private static let standardFramework = "Electron Framework.framework"
  private static let sentinel = Data("dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX".utf8)
  private static let chunkSize = 1024 * 1024
  private static let machOMagic: Set<Data> = [
    Data([0xcf, 0xfa, 0xed, 0xfe]), Data([0xfe, 0xed, 0xfa, 0xcf]),
    Data([0xce, 0xfa, 0xed, 0xfe]), Data([0xfe, 0xed, 0xfa, 0xce]),
    Data([0xca, 0xfe, 0xba, 0xbe]), Data([0xbe, 0xba, 0xfe, 0xca]),
    Data([0xca, 0xfe, 0xba, 0xbf]), Data([0xbf, 0xba, 0xfe, 0xca]),
  ]

  static func isElectron(_ app: URL, token: CancellationToken) throws -> Bool {
    try token.check()
    let frameworks = app.appending(path: "Contents/Frameworks")
    guard BundleFiles.exists(frameworks) else { return false }
    let manager = FileManager.default
    let entries = try manager.contentsOfDirectory(
      at: frameworks, includingPropertiesForKeys: [.isDirectoryKey]
    )
    .filter { $0.pathExtension == "framework" }
    .sorted {
      if ($0.lastPathComponent == standardFramework) != ($1.lastPathComponent == standardFramework)
      {
        return $0.lastPathComponent == standardFramework
      }
      return $0.path < $1.path
    }
    var visited: Set<URL> = []
    for framework in entries {
      try token.check()
      guard BundleFiles.isWithin(framework, app),
        try framework.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
      else { continue }
      // Bundle 支持 Versions/Current 链接及不同于目录名的 CFBundleExecutable。
      let executable =
        Bundle(url: framework)?.executableURL
        ?? framework.appending(path: framework.deletingPathExtension().lastPathComponent)
      let binary = BundleFiles.canonical(executable)
      guard BundleFiles.isWithin(binary, app), BundleFiles.exists(binary),
        visited.insert(binary).inserted
      else { continue }
      try BundleFiles.requireRegular(binary)
      let file = try FileHandle(forReadingFrom: binary)
      defer { try? file.close() }
      guard let magic = try file.read(upToCount: 4), machOMagic.contains(magic) else { continue }
      // 旧版 Electron 尚无 fuse，保留标准框架的识别方式。
      if framework.lastPathComponent == standardFramework { return true }
      try file.seek(toOffset: 0)
      if try containsFuse(in: file, token: token) { return true }
    }
    return false
  }

  private static func containsFuse(in file: FileHandle, token: CancellationToken) throws -> Bool {
    // 官方 wire 格式：sentinel + version(1) + count(1) + count 个开关状态。
    // https://www.electronjs.org/docs/latest/tutorial/fuses#the-hard-way
    let maximumWireSize = sentinel.count + 2 + 255
    var overlap = Data()
    while true {
      try token.check()
      guard let chunk = try file.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
      var bytes = overlap
      bytes.append(chunk)
      var start = bytes.startIndex
      while let match = bytes.range(of: sentinel, in: start..<bytes.endIndex) {
        let header = match.upperBound
        if bytes.endIndex - header >= 2, bytes[header] == 1 {
          let count = Int(bytes[header + 1])
          let states = header + 2
          if count > 0, count <= bytes.endIndex - states,
            bytes[states..<(states + count)].allSatisfy({ [0x30, 0x31, 0x72].contains($0) })
          {
            return true
          }
        }
        start = match.lowerBound + 1
      }
      // 保留完整 wire 的最大重叠区，覆盖标记、头部或状态跨块的情况。
      overlap = Data(bytes.suffix(maximumWireSize - 1))
    }
  }
}
