import Foundation

@testable import appclonecore

private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw CloneFailure("test_failed", message) }
}

@main
struct CoreChecks {
  static func main() throws {
    try checkLocalization()
    let runner = ProcessRunner()
    let cancelled = CancellationToken()
    cancelled.cancel()
    do {
      _ = try runner.run("/usr/bin/true", [], token: cancelled)
      throw CloneFailure("test_failed", "预先取消后不应执行进程。")
    } catch let error as CloneFailure {
      try require(error.code == "cancelled", "预先取消没有返回 cancelled。")
    }

    let active = CancellationToken()
    let started = Date()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { active.cancel() }
    do {
      _ = try runner.run("/bin/sleep", ["30"], token: active)
      throw CloneFailure("test_failed", "执行中的进程未取消。")
    } catch let error as CloneFailure {
      try require(error.code == "cancelled", "执行中取消没有返回 cancelled。")
    }
    try require(Date().timeIntervalSince(started) < 5, "取消后进程没有及时退出。")

    do {
      _ = try runner.run("/bin/sleep", ["30"], token: CancellationToken(), timeout: 0.1)
      throw CloneFailure("test_failed", "超时进程没有退出。")
    } catch let error as CloneFailure {
      try require(error.code == "timeout", "超时没有返回 timeout。")
    }

    let result = try runner.run(
      "/bin/dd", ["if=/dev/zero", "bs=65536", "count=2"],
      token: CancellationToken())
    try require(
      result.status == 0 && result.output.utf8.count == 65_536,
      "大于 pipe 容量的输出应完成且读取上限为 64 KiB。")
    print("Swift 核心检查通过：预取消、执行中取消、超时、输出容量。")
  }

  private static func checkLocalization() throws {
    let cases: [([String: String], [String], AppLanguage)] = [
      (["LC_ALL": "en_US.UTF-8", "LC_MESSAGES": "zh_CN", "LANG": "zh_CN"], ["zh"], .en),
      (["LC_ALL": "", "LC_MESSAGES": "zh_CN", "LANG": "en_US"], ["en"], .zh),
      (["LANG": "zh-Hans-CN"], ["en"], .zh),
      ([:], ["zh-Hant-TW"], .zh),
      ([:], ["en-GB"], .en),
      (["LANG": "C"], ["zh"], .en),
      (["LANG": "de_DE.UTF-8"], ["zh"], .en),
      ([:], [], .en),
    ]
    for (environment, preferred, expected) in cases {
      try require(
        AppLanguage.detect(environment: environment, preferredLanguages: preferred) == expected,
        "语言检测优先级不正确。")
    }
    for message in L10n.Message.allCases {
      let zh = L10n.translation(message, language: .zh)
      let en = L10n.translation(message, language: .en)
      try require(!zh.isEmpty && !en.isEmpty, "缺少翻译：\(message)")
      try require(
        zh.components(separatedBy: "{}").count == en.components(separatedBy: "{}").count,
        "翻译参数数量不一致：\(message)")
    }
    try L10n.$language.withValue(.en) {
      try require(
        L10n.text(.nameConflict, "工作 {} %s") == "A clone with this name already exists: 工作 {} %s",
        "用户参数不应作为翻译模板解析。")
      let token = CancellationToken()
      // Signal callbacks run outside the task-local scope; the token must keep its language.
      L10n.$language.withValue(.zh) { token.cancel() }
      do {
        try token.check()
        throw CloneFailure("test_failed", "取消没有返回错误。")
      } catch let error as CloneFailure {
        try require(error.message == "Operation cancelled.", "取消提示丢失语言。")
      }
      do {
        _ = try ProcessRunner().run(
          "/bin/sleep", ["30"], token: CancellationToken(), timeout: 0.05)
        throw CloneFailure("test_failed", "超时没有返回错误。")
      } catch let error as CloneFailure {
        try require(error.message == "Command timed out: /bin/sleep", "超时提示丢失语言。")
      }
    }
    print("Swift 国际化检查通过：语言选择、翻译完整性、参数、取消和超时。")
  }
}
