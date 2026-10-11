import Foundation

@testable import appclonecore

@main
struct EnvironmentChecks {
  static func require(_ condition: Bool, _ message: String) {
    precondition(condition, message)
  }

  static func rejects(_ body: () throws -> Void) {
    do {
      try body()
      preconditionFailure("Expected rejection")
    } catch {}
  }

  static func write(
    _ value: UInt64, width: Int = 4, at offset: Int, into bytes: inout [UInt8],
    bigEndian: Bool = false
  ) {
    for index in 0..<width {
      bytes[offset + index] = UInt8(
        truncatingIfNeeded: value >> ((bigEndian ? width - index - 1 : index) * 8))
    }
  }

  static func thin(cpu: UInt64 = 0x0100_000c) -> Data {
    var bytes = [UInt8](repeating: 0, count: 1024)
    write(0xfeed_facf, at: 0, into: &bytes)
    write(cpu, at: 4, into: &bytes)
    write(2, at: 12, into: &bytes)
    write(1, at: 16, into: &bytes)
    write(152, at: 20, into: &bytes)
    write(0x19, at: 32, into: &bytes)
    write(152, at: 36, into: &bytes)
    write(1024, width: 8, at: 80, into: &bytes)
    write(1, at: 96, into: &bytes)
    write(16, width: 8, at: 144, into: &bytes)
    write(768, at: 152, into: &bytes)
    return Data(bytes)
  }

  static func fat(is64: Bool) -> Data {
    var bytes = [UInt8](repeating: 0, count: 3072)
    write(is64 ? 0xcafe_babf : 0xcafe_babe, at: 0, into: &bytes, bigEndian: true)
    write(2, at: 4, into: &bytes, bigEndian: true)
    for (index, cpu) in [UInt64(0x0100_000c), UInt64(0x0100_0007)].enumerated() {
      let entry = 8 + index * (is64 ? 32 : 20)
      let offset = 1024 + index * 1024
      write(cpu, at: entry, into: &bytes, bigEndian: true)
      write(UInt64(offset), width: is64 ? 8 : 4, at: entry + 8, into: &bytes, bigEndian: true)
      write(1024, width: is64 ? 8 : 4, at: entry + (is64 ? 16 : 12), into: &bytes, bigEndian: true)
      write(10, at: entry + (is64 ? 24 : 16), into: &bytes, bigEndian: true)
      bytes.replaceSubrange(offset..<(offset + 1024), with: thin(cpu: cpu))
    }
    return Data(bytes)
  }

  static func main() throws {
    let path = "@executable_path/../Frameworks/libappclone_env.dylib"
    for original in [thin(), thin(cpu: 0x0100_0007), fat(is64: false), fat(is64: true)] {
      let inserted = try MachOInjector.insertingDylib(path, into: original)
      require(
        inserted != original && inserted.count == original.count,
        "Insertion must preserve file size")
      require(
        try MachOInjector.insertingDylib(path, into: inserted) == inserted,
        "Insertion must be idempotent")
      require(
        try MachOInjector.removingDylib(path, from: inserted) == original,
        "Reset must restore load commands")
      let later = try MachOInjector.insertingDylib("@executable_path/another.dylib", into: inserted)
      rejects { _ = try MachOInjector.removingDylib(path, from: later) }
      rejects { _ = try MachOInjector.removingDylib(path, from: original) }
    }
    for length in 0..<32 {
      rejects { _ = try MachOInjector.insertingDylib(path, into: Data(thin().prefix(length))) }
    }
    var occupied = thin()
    occupied[184] = 1
    rejects { _ = try MachOInjector.insertingDylib(path, into: occupied) }
    var unsupported = thin()
    unsupported[4] = 0
    rejects { _ = try MachOInjector.insertingDylib(path, into: unsupported) }
    var brokenFat = fat(is64: true)
    brokenFat[8 + 16] = 0x7f
    rejects { _ = try MachOInjector.insertingDylib(path, into: brokenFat) }
    let root = URL(fileURLWithPath: "/example/数据\"quoted")
    let source = try EnvironmentSource.generate(
      variables: ["HOME": "{{APP_CLONE_DATA_DIR}}/home"], dataDirectory: root)
    require(source.contains("appclone_env_init"), "Project constructor name")
    require(!source.contains("{{"), "Data directory placeholder must expand")
    require(source.contains("\\\"quoted/home"), "Quotes in paths must be escaped")
    rejects {
      _ = try EnvironmentSource.generate(variables: ["BAD-NAME": "value"], dataDirectory: root)
    }
    rejects {
      _ = try EnvironmentSource.generate(variables: ["NAME": "nul\0value"], dataDirectory: root)
    }
    print("Swift 环境检查通过：薄文件、FAT32/FAT64、重复注入、移除、损坏输入和源码转义。")
  }
}
