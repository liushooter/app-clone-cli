import Foundation

public struct CloneFailure: Error, LocalizedError, Sendable {
  public let code: String
  public let message: String
  public var errorDescription: String? { message }

  public init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }
}

public struct AppDescriptor: Codable, Sendable {
  public let path: String
  public let name: String
  public let bundleID: String
  public let version: String
  public let build: String
  public let executable: String
  public let iconFile: String?
  public let iconName: String?
}

public struct CloneRecord: Codable, Sendable {
  public let id: String
  public var name: String
  public let bundleID: String
  public var appFileName: String?
  public let cloneNumber: Int?
  public var source: AppDescriptor
  public let createdAt: Date
  public var modifiedAt: Date
  public var customIconSHA256: String?
  public let compatibility: String
}

public struct CloneStatistics: Encodable, Sendable {
  public let sourceBundleID: String
  public let sourceName: String
  public let totalCreated: Int
  public let currentCount: Int
  public let historyComplete: Bool
}

struct CloneCounter: Codable {
  var name: String
  var totalCreated: Int
}

struct Catalog: Codable {
  var schemaVersion = 3
  var revision = UUID().uuidString.lowercased()
  var clones: [CloneRecord] = []
  var creationCounts: [String: CloneCounter]? = [:]
  var historyComplete: Bool? = true

  func trackingCreations() -> Catalog {
    var result = self
    result.schemaVersion = 3
    if result.creationCounts == nil {
      result.creationCounts = Dictionary(grouping: clones, by: { $0.source.bundleID })
        .mapValues { records in
          CloneCounter(
            name: records[0].source.name,
            totalCreated: max(records.count, records.compactMap(\.cloneNumber).max() ?? 0))
        }
    }
    result.historyComplete = historyComplete ?? false
    return result
  }
}

public struct CloneEvent: Codable, Sendable {
  public let stage: String
  public let message: String

  public init(_ stage: String, _ message: String) {
    self.stage = stage
    self.message = message
  }
}

public typealias EventHandler = @Sendable (CloneEvent) -> Void

public enum JSONCoding {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
  }
}
