import Foundation
import MachO

/// 仅读取各架构的 Mach-O 头部和 load commands，不加载或扫描程序内容。
enum MachOPlatforms {
  static func read(_ executable: URL) throws -> Set<UInt32> {
    let file = try FileHandle(forReadingFrom: executable)
    defer { try? file.close() }
    let reader = Reader(file: file, length: try file.seekToEnd())
    guard reader.length >= 4 else { return [] }
    let magic = uint32(try reader.bytes(at: 0, count: 4), at: 0, littleEndian: false)
    guard [FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64].contains(magic) else {
      return try platforms(in: reader, offset: 0, size: reader.length)
    }
    let littleEndian = magic == FAT_CIGAM || magic == FAT_CIGAM_64
    let is64 = magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64
    let header = try reader.bytes(at: 0, count: 8)
    let count = Int(uint32(header, at: 4, littleEndian: littleEndian))
    let entrySize = is64 ? 32 : 20
    guard count > 0, count <= 64 else { throw invalidBinary() }
    let table = try reader.bytes(at: 8, count: count * entrySize)
    let tableEnd = UInt64(8 + table.count)
    var slices: [(offset: UInt64, size: UInt64)] = []
    for index in 0..<count {
      let entry = index * entrySize
      let offset =
        is64
        ? uint64(table, at: entry + 8, littleEndian: littleEndian)
        : UInt64(uint32(table, at: entry + 8, littleEndian: littleEndian))
      let size =
        is64
        ? uint64(table, at: entry + 16, littleEndian: littleEndian)
        : UInt64(uint32(table, at: entry + 12, littleEndian: littleEndian))
      guard offset >= tableEnd, offset <= reader.length, size >= 28,
        size <= reader.length - offset
      else { throw invalidBinary() }
      slices.append((offset, size))
    }
    slices.sort { $0.offset < $1.offset }
    var end = tableEnd
    var result: Set<UInt32> = []
    for slice in slices {
      guard slice.offset >= end else { throw invalidBinary() }
      result.formUnion(try platforms(in: reader, offset: slice.offset, size: slice.size))
      end = slice.offset + slice.size
    }
    return result
  }

  private static func platforms(in reader: Reader, offset: UInt64, size: UInt64) throws
    -> Set<UInt32>
  {
    let magic = uint32(try reader.bytes(at: offset, count: 4), at: 0, littleEndian: false)
    // 保持对脚本启动器等非 Mach-O 主程序的既有支持。
    guard [MH_MAGIC, MH_CIGAM, MH_MAGIC_64, MH_CIGAM_64].contains(magic) else { return [] }
    let littleEndian = magic == MH_CIGAM || magic == MH_CIGAM_64
    let headerSize = magic == MH_MAGIC_64 || magic == MH_CIGAM_64 ? 32 : 28
    guard size >= UInt64(headerSize) else { throw invalidBinary() }
    let header = try reader.bytes(at: offset, count: headerSize)
    let count = Int(uint32(header, at: 16, littleEndian: littleEndian))
    let commandSize = Int(uint32(header, at: 20, littleEndian: littleEndian))
    guard commandSize <= 16 * 1024 * 1024, UInt64(commandSize) <= size - UInt64(headerSize),
      count <= commandSize / 8
    else { throw invalidBinary() }
    let commands = try reader.bytes(at: offset + UInt64(headerSize), count: commandSize)
    var result: Set<UInt32> = []
    var legacy: Set<UInt32> = []
    var cursor = 0
    for _ in 0..<count {
      guard commands.count - cursor >= 8 else { throw invalidBinary() }
      let kind = uint32(commands, at: cursor, littleEndian: littleEndian)
      let length = Int(uint32(commands, at: cursor + 4, littleEndian: littleEndian))
      guard length >= 8, length % 4 == 0, length <= commands.count - cursor else {
        throw invalidBinary()
      }
      if kind == LC_BUILD_VERSION {
        guard length >= 24 else { throw invalidBinary() }
        let tools = Int(uint32(commands, at: cursor + 20, littleEndian: littleEndian))
        guard tools <= (length - 24) / 8 else { throw invalidBinary() }
        result.insert(uint32(commands, at: cursor + 8, littleEndian: littleEndian))
      } else if kind == LC_VERSION_MIN_IPHONEOS || kind == LC_VERSION_MIN_MACOSX {
        guard length >= 16 else { throw invalidBinary() }
        legacy.insert(
          kind == LC_VERSION_MIN_IPHONEOS ? UInt32(PLATFORM_IOS) : UInt32(PLATFORM_MACOS))
      }
      cursor += length
    }
    guard cursor == commands.count else { throw invalidBinary() }
    return result.isEmpty ? legacy : result
  }

  private static func uint32(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { value, index in
      value | UInt32(data[offset + index]) << ((littleEndian ? index : 3 - index) * 8)
    }
  }

  private static func uint64(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { value, index in
      value | UInt64(data[offset + index]) << ((littleEndian ? index : 7 - index) * 8)
    }
  }

  private static func invalidBinary() -> CloneFailure {
    CloneFailure("invalid_bundle", L10n.text(.invalidBundle))
  }

  private struct Reader {
    let file: FileHandle
    let length: UInt64

    func bytes(at offset: UInt64, count: Int) throws -> Data {
      guard count >= 0, offset <= length, UInt64(count) <= length - offset else {
        throw invalidBinary()
      }
      try file.seek(toOffset: offset)
      guard let data = try file.read(upToCount: count), data.count == count else {
        if count == 0 { return Data() }
        throw invalidBinary()
      }
      return data
    }
  }
}
