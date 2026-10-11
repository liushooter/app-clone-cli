import Darwin
import Foundation
import appclonecore

private struct Options {
  let command: String
  var positional: [String] = []
  var values: [String: String] = [:]
  var json = false
  var reset = false
  var showHelp = false

  init(_ arguments: [String]) throws {
    let first = arguments.first ?? "help"
    command = ["--version": "version", "create": "clone"][first] ?? first
    if command == "--help" || command == "help" { return }
    let specs: [String: (Int, Set<String>)] = [
      "doctor": (0, []), "inspect": (1, []), "list": (0, []), "stats": (0, []),
      "clone": (1, ["name", "icon"]), "icon": (2, []),
      "verify": (1, []), "remove": (1, []),
      "rename": (2, []),
      "adv-clone": (1, ["data-dir", "proxy", "locale"]),
      "register": (0, []),
      "version": (0, []),
    ]
    guard let spec = specs[command] else {
      throw CloneFailure("usage", L10n.text(.unknownCommand, command))
    }
    var index = 1
    var positionalOnly = false
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--", !positionalOnly {
        positionalOnly = true
      } else if argument == "--json", !positionalOnly {
        json = true
      } else if argument == "--reset", command == "adv-clone", !positionalOnly, !reset {
        reset = true
      } else if argument == "--help", command == "adv-clone", !positionalOnly, !showHelp {
        showHelp = true
      } else if argument.hasPrefix("--"), !positionalOnly {
        let key = String(argument.dropFirst(2))
        guard spec.1.contains(key) || key == "workspace", values[key] == nil,
          index + 1 < arguments.count
        else {
          throw CloneFailure("usage", L10n.text(.invalidOption, argument))
        }
        index += 1
        values[key] = arguments[index]
      } else {
        positional.append(argument)
      }
      index += 1
    }
    if command == "adv-clone" {
      guard !reset || values.keys.allSatisfy({ $0 == "workspace" }) else {
        throw CloneFailure("usage", L10n.text(.resetEnvironmentUsage))
      }
      if positional.isEmpty && values.isEmpty && !reset { showHelp = true }
    }
    guard positional.count == spec.0 || (showHelp && positional.count <= 1),
      command != "clone" || values["name"] != nil
    else {
      throw CloneFailure("usage", L10n.text(.incompleteArguments, command))
    }
  }
}

private struct ToolCheck: Encodable {
  let path: String
  let available: Bool
}

private struct CommandError: Encodable {
  let code: String
  let message: String
}

@main
struct AppCloneCLI {

  static func main() async {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var language = AppLanguage.detect()
    do {
      try extractLanguage(from: &arguments, language: &language)
    } catch {
      L10n.$language.withValue(language) {
        report(error, json: arguments.prefix { $0 != "--" }.contains("--json"))
      }
      Darwin.exit(1)
    }
    await L10n.$language.withValue(language) { await run(arguments) }
  }

  /// Recognize --lang before or after the command, but never inside option values or after --.
  private static func extractLanguage(from arguments: inout [String], language: inout AppLanguage)
    throws
  {
    var remaining: [String] = []
    var index = 0
    var seen = false
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--" {
        remaining.append(contentsOf: arguments[index...])
        break
      }
      if argument == "--lang" {
        guard !seen, index + 1 < arguments.count,
          let selected = AppLanguage(rawValue: arguments[index + 1])
        else {
          throw L10n.$language.withValue(language) {
            CloneFailure("usage", L10n.text(.invalidLanguage))
          }
        }
        language = selected
        seen = true
        index += 2
      } else {
        remaining.append(argument)
        index += 1
        if ["--name", "--icon", "--workspace", "--data-dir", "--proxy", "--locale"].contains(
          argument), index < arguments.count
        {
          remaining.append(arguments[index])
          index += 1
        }
      }
    }
    arguments = remaining
  }

  private static func run(_ arguments: [String]) async {
    let json = arguments.contains("--json")
    do {
      let options = try Options(arguments)
      if ["help", "--help"].contains(options.command) {
        print(CLIHelp.text)
        return
      }
      if options.command == "adv-clone", options.showHelp {
        print(CLIHelp.advClone)
        return
      }
      if options.command == "version" {
        if options.json {
          try output(["version": AppCloneVersion.current])
        } else {
          print("app-clone \(AppCloneVersion.current)")
        }
        return
      }
      let token = CancellationToken()
      signal(SIGINT, SIG_IGN)
      signal(SIGTERM, SIG_IGN)
      let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .utility))
      let terminate = DispatchSource.makeSignalSource(
        signal: SIGTERM, queue: .global(qos: .utility))
      for source in [interrupt, terminate] {
        source.setEventHandler { token.cancel() }
        source.resume()
      }
      defer {
        interrupt.cancel()
        terminate.cancel()
      }
      try await execute(options, token: token)
    } catch {
      report(error, json: json)
      Darwin.exit((error as? CloneFailure)?.code == "cancelled" ? 130 : 1)
    }
  }

  private static func report(_ error: Error, json: Bool) {
    let output = CommandError(
      code: (error as? CloneFailure)?.code ?? "operation_failed",
      message: error.localizedDescription)
    if json, let data = try? JSONCoding.encode(output) {
      FileHandle.standardError.write(data + Data("\n".utf8))
    } else {
      FileHandle.standardError.write(Data((L10n.text(.errorLine, output.message) + "\n").utf8))
    }
  }

  @MainActor
  private static func execute(_ options: Options, token: CancellationToken) async throws {
    let workspaceURL: URL
    if let path = options.values["workspace"] {
      workspaceURL = url(path)
    } else if ["icon", "rename", "verify", "remove", "adv-clone"].contains(options.command) {
      workspaceURL = try CloneEngine.workspaceRoot(for: url(options.positional[0]))
    } else {
      workspaceURL = CloneEngine.defaultRoot
    }
    let engine = CloneEngine(root: workspaceURL)
    let events: EventHandler = { event in
      if !options.json {
        FileHandle.standardError.write(Data("[\(event.stage)] \(event.message)\n".utf8))
      }
    }
    switch options.command {
    case "doctor":
      let checks = ["/usr/bin/ditto", "/usr/bin/xattr", "/usr/bin/codesign"]
        .map { ToolCheck(path: $0, available: FileManager.default.isExecutableFile(atPath: $0)) }
      if options.json {
        try output(checks)
      } else {
        for check in checks {
          print(L10n.text(check.available ? .toolAvailableLine : .toolUnavailableLine, check.path))
        }
      }
      if checks.contains(where: { !$0.available }) {
        throw CloneFailure("missing_tools", L10n.text(.missingTools))
      }
    case "inspect":
      let descriptor = try await background { try AppInspector.inspect(url(options.positional[0])) }
      try output(descriptor)
    case "list":
      let records = try await background { try engine.list() }
      if options.json {
        try output(records)
      } else if records.isEmpty {
        print(L10n.text(.emptyList))
      } else {
        for record in records {
          let path = engine.root.appendingPathComponent("apps")
            .appendingPathComponent(record.appFileName ?? record.id + ".app")
          print(
            "\(record.name)  \(record.customIconSHA256 == nil ? L10n.text(.originalIcon) : L10n.text(.customIcon))\n  \(path.path)"
          )
        }
      }
    case "stats":
      let statistics = try await background { try engine.statistics() }
      if options.json {
        try output(statistics)
      } else if statistics.isEmpty {
        print(L10n.text(.emptyStats))
      } else {
        for item in statistics {
          let history = item.historyComplete ? "" : L10n.text(.incompleteHistory)
          print(
            L10n.text(
              .statisticsLine, item.sourceName, item.sourceBundleID,
              String(item.totalCreated), String(item.currentCount), history)
          )
        }
      }
    case "register":
      let results = try await background { try engine.registerApplications() }
      try output(results)
      if results.contains(where: { $0.status != 0 }) {
        throw CloneFailure("registration_failed", L10n.text(.registrationFailed))
      }
    case "clone":
      let record = try await background {
        try engine.create(
          source: url(options.positional[0]), name: options.values["name"]!,
          icon: options.values["icon"].map(url), token: token, onEvent: events)
      }
      try output(record)
    case "icon":
      let record = try await background {
        try engine.replaceIcon(
          app: url(options.positional[0]), icon: url(options.positional[1]),
          token: token, onEvent: events)
      }
      try output(record)
    case "adv-clone":
      let record = try await background {
        try engine.configureEnvironment(
          app: url(options.positional[0]), dataDirectory: options.values["data-dir"].map(url),
          proxy: options.values["proxy"], locale: options.values["locale"], reset: options.reset,
          token: token, onEvent: events)
      }
      if options.json {
        try output(record)
      } else if let settings = record.environment {
        print(L10n.text(.environmentEnabled))
        if let directory = settings.dataDirectory {
          print(L10n.text(.environmentDataLine, directory))
        }
        if let proxy = settings.proxy { print(L10n.text(.environmentProxyLine, proxy)) }
        if let locale = settings.locale { print(L10n.text(.environmentLocaleLine, locale)) }
      } else {
        print(L10n.text(.environmentDisabled))
      }
    case "verify":
      let record = try await background {
        try engine.verify(app: url(options.positional[0]), token: token)
      }
      try output(record)
    case "rename":
      let record = try await background {
        try engine.rename(
          app: url(options.positional[0]), name: options.positional[1], token: token,
          onEvent: events)
      }
      try output(record)
    case "remove":
      let record = try await background {
        try engine.remove(app: url(options.positional[0]), token: token, onEvent: events)
      }
      try output(record)
    default: break
    }
  }

  private static func url(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
  }

  private static func output<T: Encodable>(_ value: T) throws {
    FileHandle.standardOutput.write(try JSONCoding.encode(value) + Data("\n".utf8))
  }

  private static func background<T: Sendable>(_ body: @escaping @Sendable () throws -> T)
    async throws -> T
  {
    let language = L10n.language
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        L10n.$language.withValue(language) {
          continuation.resume(with: Result { try body() })
        }
      }
    }
  }
}
