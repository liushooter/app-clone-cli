import Darwin
import Foundation

/// One token per operation. Idle tokens have no timer, thread, or process.
public final class CancellationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var failure: CloneFailure?
  private var process: Process?
  private var escalation: DispatchWorkItem?
  private let language = L10n.language

  public init() {}

  public func check() throws {
    lock.lock()
    defer { lock.unlock() }
    if let failure { throw failure }
  }

  public func cancel() {
    let message = L10n.$language.withValue(language) { L10n.text(.cancelled) }
    cancel(with: CloneFailure("cancelled", message))
  }

  func cancel(with reason: CloneFailure) {
    lock.lock()
    defer { lock.unlock() }
    if failure == nil { failure = reason }
    guard let process, process.isRunning else { return }
    process.terminate()
    if escalation == nil {
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        if let active = self.process, active.isRunning {
          Darwin.kill(active.processIdentifier, SIGKILL)
        }
      }
      escalation = work
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }
  }

  func start(_ process: Process) throws {
    lock.lock()
    defer { lock.unlock() }
    if let failure { throw failure }
    try process.run()
    self.process = process
  }

  func finish() {
    lock.lock()
    defer { lock.unlock() }
    escalation?.cancel()
    escalation = nil
    process = nil
  }
}

public struct ProcessResult: Sendable {
  public let status: Int32
  public let output: String
}

public struct ProcessRunner: Sendable {
  public init() {}

  /// Blocking by design: call from a worker queue, never from SwiftUI's main actor.
  /// Output goes to a temporary file so a full pipe cannot deadlock the child.
  public func run(
    _ executable: String, _ arguments: [String],
    token: CancellationToken, timeout: TimeInterval = 600,
    requireSuccess: Bool = true
  ) throws -> ProcessResult {
    try token.check()
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent(
      "app-clone-process-" + UUID().uuidString.lowercased())
    try fm.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: directory) }
    let log = directory.appendingPathComponent("output.log")
    guard
      fm.createFile(
        atPath: log.path, contents: nil,
        attributes: [.posixPermissions: 0o600])
    else {
      throw CloneFailure("output_failed", L10n.text(.outputFailed))
    }
    let writer = try FileHandle(forWritingTo: log)
    defer { try? writer.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = writer
    process.standardError = writer
    process.standardInput = FileHandle.nullDevice
    try token.start(process)
    defer { token.finish() }
    let timeoutFailure = CloneFailure("timeout", L10n.text(.timeout, executable))
    let timer = DispatchWorkItem { token.cancel(with: timeoutFailure) }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
    defer { timer.cancel() }
    process.waitUntilExit()
    try token.check()
    try writer.synchronize()
    let reader = try FileHandle(forReadingFrom: log)
    defer { try? reader.close() }
    let data = try reader.read(upToCount: 65_536) ?? Data()
    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let result = ProcessResult(status: process.terminationStatus, output: output)
    if requireSuccess && result.status != 0 {
      throw CloneFailure(
        "command_failed",
        L10n.text(
          .commandFailed, URL(fileURLWithPath: executable).lastPathComponent,
          String(result.status), output))
    }
    return result
  }
}
