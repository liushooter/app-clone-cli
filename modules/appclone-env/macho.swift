// 检查 Mach-O 边界和头部余量，在内存副本中插入或移除动态库依赖。
// 由 adv-clone 命令调用；不负责写文件、签名或加载动态库。

import Foundation

enum MachOInjector {
  struct Failure: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
  }

  private struct Slice {
    let offset: Int
    let size: Int
  }

  /// 检查 Mach-O 头部余量并插入动态库依赖。
  /// 单架构、通用二进制中的所有切片都通过检查后，才返回修改后的数据。
  static func insertingDylib(_ path: String, into original: Data) throws -> Data {
    try updatingDylib(path, in: original, removing: false)
  }

  /// 仅移除最后一个动态库依赖，保留既有库的序号及所有节区偏移。
  static func removingDylib(_ path: String, from original: Data) throws -> Data {
    try updatingDylib(path, in: original, removing: true)
  }

  private static func updatingDylib(_ path: String, in original: Data, removing: Bool) throws
    -> Data
  {
    let pathBytes = Array(path.utf8)
    guard !pathBytes.isEmpty, !pathBytes.contains(0), pathBytes.count < 4096 else {
      throw Failure(reason: "动态库路径为空、包含 NUL 或过长。")
    }

    // LC_LOAD_DYLIB = 24 字节固定字段 + 路径 + NUL；总长度按 8 字节对齐。
    let commandSize = (24 + pathBytes.count + 1 + 7) & ~7
    var command = Bytes(storage: Array(repeating: 0, count: commandSize))
    command.write32(0x0c, at: 0)
    command.write32(UInt32(commandSize), at: 4)
    command.write32(24, at: 8)
    command.storage.replaceSubrange(24..<(24 + pathBytes.count), with: pathBytes)

    var result = Bytes(storage: Array(original))
    for slice in try slices(in: result) {
      try insert(command.storage, path: pathBytes, into: &result, slice: slice, removing: removing)
    }
    return Data(result.storage)
  }

  private static func slices(in bytes: Bytes) throws -> [Slice] {
    if try bytes.read32(at: 0) == 0xfeed_facf {
      return [Slice(offset: 0, size: bytes.storage.count)]
    }

    // FAT 文件头描述各个架构切片。支持常见 FAT32，也展示 FAT64 的读取方式。
    let magic = try bytes.read32(at: 0, bigEndian: true)
    guard [0xcafe_babe, 0xcafe_babf, 0xbeba_feca, 0xbfba_feca].contains(magic) else {
      throw Failure(reason: "不支持的 Mach-O 格式。")
    }
    let bigEndian = magic == 0xcafe_babe || magic == 0xcafe_babf
    let isFat64 = magic == 0xcafe_babf || magic == 0xbfba_feca
    let entrySize = isFat64 ? 32 : 20
    let count = Int(try bytes.read32(at: 4, bigEndian: bigEndian))
    guard count > 0, count <= (bytes.storage.count - 8) / entrySize else {
      throw Failure(reason: "通用二进制的架构表不完整。")
    }
    let tableEnd = 8 + count * entrySize
    var result: [Slice] = []
    for index in 0..<count {
      let entry = 8 + index * entrySize
      let offset: UInt64
      let size: UInt64
      if isFat64 {
        offset = try bytes.read64(at: entry + 8, bigEndian: bigEndian)
        size = try bytes.read64(at: entry + 16, bigEndian: bigEndian)
      } else {
        offset = UInt64(try bytes.read32(at: entry + 8, bigEndian: bigEndian))
        size = UInt64(try bytes.read32(at: entry + 12, bigEndian: bigEndian))
      }
      guard let start = Int(exactly: offset), let length = Int(exactly: size),
        start >= tableEnd, length >= 32
      else { throw Failure(reason: "无效的架构切片范围。") }
      try bytes.require(start, length)
      result.append(Slice(offset: start, size: length))
    }
    let sorted = result.sorted { $0.offset < $1.offset }
    for index in 1..<sorted.count {
      guard sorted[index - 1].offset + sorted[index - 1].size <= sorted[index].offset else {
        throw Failure(reason: "架构切片互相重叠。")
      }
    }
    return result
  }

  private static func insert(
    _ command: [UInt8], path: [UInt8], into bytes: inout Bytes, slice: Slice, removing: Bool
  ) throws {
    let base = slice.offset
    guard slice.size >= 32, try bytes.read32(at: base) == 0xfeed_facf,
      try bytes.read32(at: base + 12) == 2
    else { throw Failure(reason: "仅支持 64 位小端 Mach-O 可执行文件。") }
    let cpu = try bytes.read32(at: base + 4)
    guard cpu == 0x0100_000c || cpu == 0x0100_0007 else {
      throw Failure(reason: "仅支持 Apple Silicon 和 Intel 64 位切片。")
    }

    let count = Int(try bytes.read32(at: base + 16))
    let size = Int(try bytes.read32(at: base + 20))
    guard size <= slice.size - 32, count <= size / 8 else {
      throw Failure(reason: "Mach-O 加载命令超出切片范围。")
    }
    let commandsEnd = base + 32 + size
    var cursor = base + 32
    var firstContent = slice.size
    var headerSegmentEnd = 0
    var alreadyLinked = false
    var matchedRange: Range<Int>?
    var dependencyAfterMatch = false

    for _ in 0..<count {
      guard cursor <= commandsEnd - 8 else {
        throw Failure(reason: "加载命令数量与长度不匹配。")
      }
      let kind = try bytes.read32(at: cursor)
      let length = Int(try bytes.read32(at: cursor + 4))
      guard length >= 8, length % 8 == 0, length <= commandsEnd - cursor else {
        throw Failure(reason: "无效的加载命令长度。")
      }

      if kind == 0x19 {  // LC_SEGMENT_64，包含段信息和 section_64 数组。
        guard length >= 72 else { throw Failure(reason: "段信息不完整。") }
        let fileOffset = try bytes.read64(at: cursor + 40)
        let fileSize = try bytes.read64(at: cursor + 48)
        guard fileOffset <= UInt64(slice.size), fileSize <= UInt64(slice.size) - fileOffset else {
          throw Failure(reason: "段超出切片范围。")
        }
        if fileOffset == 0, fileSize > 0 {
          headerSegmentEnd = Int(fileSize)
        } else if fileSize > 0 {
          firstContent = min(firstContent, Int(fileOffset))
        }
        let sections = Int(try bytes.read32(at: cursor + 64))
        guard sections <= (length - 72) / 80 else {
          throw Failure(reason: "节区表超出加载命令范围。")
        }
        for index in 0..<sections {
          let section = cursor + 72 + index * 80
          let sectionSize = try bytes.read64(at: section + 40)
          let sectionOffset = Int(try bytes.read32(at: section + 48))
          let sectionType = try bytes.read32(at: section + 64) & 0xff
          // 零填充节区只占虚拟内存，不占文件内容。
          if sectionSize == 0 || [1, 0x0c, 0x12].contains(sectionType) { continue }
          guard sectionOffset >= 32 + size, sectionOffset <= slice.size,
            sectionSize <= UInt64(slice.size - sectionOffset)
          else { throw Failure(reason: "节区与文件头重叠或超出切片范围。") }
          firstContent = min(firstContent, sectionOffset)
        }
      } else if [0x0c, 0x8000_0018, 0x8000_001f, 0x20, 0x8000_0023].contains(kind) {
        if matchedRange != nil { dependencyAfterMatch = true }
        // 只检查动态库命令；LC_RPATH 只是搜索目录，不表示已经依赖该库。
        guard length >= 24 else { throw Failure(reason: "动态库命令不完整。") }
        let nameOffset = Int(try bytes.read32(at: cursor + 8))
        guard nameOffset >= 24, nameOffset < length,
          let end = bytes.storage[(cursor + nameOffset)..<(cursor + length)].firstIndex(of: 0)
        else { throw Failure(reason: "动态库路径缺少合法边界或 NUL 结尾。") }
        if Array(bytes.storage[(cursor + nameOffset)..<end]) == path {
          // 弱依赖、延迟加载等不能作为“启动时一定执行”的替代。
          guard kind == 0x0c else {
            throw Failure(reason: "同名动态库已采用其他加载方式。")
          }
          alreadyLinked = true
          guard matchedRange == nil else {
            throw Failure(reason: "存在重复的动态库依赖。")
          }
          matchedRange = cursor..<(cursor + length)
        }
      } else if kind == 0x2c {  // LC_ENCRYPTION_INFO_64
        guard length >= 24, try bytes.read32(at: cursor + 16) == 0 else {
          throw Failure(reason: "不支持修改加密的可执行文件。")
        }
      }
      cursor += length
    }
    guard cursor == commandsEnd else { throw Failure(reason: "加载命令总长度不匹配。") }
    if removing {
      guard let matchedRange else { throw Failure(reason: "没有找到待移除的动态库依赖。") }
      guard !dependencyAfterMatch else {
        throw Failure(reason: "待移除的动态库不是最后一个依赖。")
      }
      let remainder = Array(bytes.storage[matchedRange.upperBound..<commandsEnd])
      bytes.storage.replaceSubrange(
        matchedRange.lowerBound..<commandsEnd,
        with: remainder + Array(repeating: 0, count: matchedRange.count))
      bytes.write32(UInt32(count - 1), at: base + 16)
      bytes.write32(UInt32(size - matchedRange.count), at: base + 20)
      return
    }
    if alreadyLinked { return }

    // 只占用头部段内已有的全零预留空间，不搬移任何节区。
    let contentStart = min(firstContent, headerSegmentEnd)
    guard contentStart >= 32 + size, command.count <= contentStart - (32 + size),
      bytes.storage[commandsEnd..<(commandsEnd + command.count)].allSatisfy({ $0 == 0 }),
      UInt64(size) + UInt64(command.count) <= UInt32.max
    else { throw Failure(reason: "没有足够的全零头部预留空间。") }

    bytes.storage.replaceSubrange(commandsEnd..<(commandsEnd + command.count), with: command)
    bytes.write32(UInt32(count + 1), at: base + 16)
    bytes.write32(UInt32(size + command.count), at: base + 20)
  }

  /// 明确按字节读写，避免直接将 Data 指针转成结构体产生对齐问题。
  private struct Bytes {
    var storage: [UInt8]

    func require(_ offset: Int, _ length: Int) throws {
      guard offset >= 0, length >= 0, offset <= storage.count, length <= storage.count - offset
      else {
        throw Failure(reason: "读取范围超出文件边界。")
      }
    }

    func read32(at offset: Int, bigEndian: Bool = false) throws -> UInt32 {
      try require(offset, 4)
      return (0..<4).reduce(UInt32(0)) { value, index in
        value | UInt32(storage[offset + index]) << ((bigEndian ? 3 - index : index) * 8)
      }
    }

    func read64(at offset: Int, bigEndian: Bool = false) throws -> UInt64 {
      try require(offset, 8)
      return (0..<8).reduce(UInt64(0)) { value, index in
        value | UInt64(storage[offset + index]) << ((bigEndian ? 7 - index : index) * 8)
      }
    }

    // 写入位置来自已验证的固定头部，写入格式为小端。
    mutating func write32(_ value: UInt32, at offset: Int) {
      for index in 0..<4 {
        storage[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
      }
    }
  }
}
