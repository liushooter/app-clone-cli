// 将分身环境变量和界面语言转换为 C / Objective-C 初始化源码。
// 由 env 命令调用。此文件只生成源码，不修改当前进程的环境变量。

import Foundation

enum EnvironmentSource {
  enum Failure: Error {
    case invalidVariable(String)
    case valueContainsNul(String)
  }

  /// 把分身配置转换为 libappclone_env.dylib 的源码，不经过 shell 文本。
  static func generate(
    variables: [String: String], dataDirectory: URL, appLanguage: String? = nil
  ) throws -> String {
    var lines = [
      "    const char *orig_home = getenv(\"HOME\");",
      "    if (orig_home && !getenv(\"APP_CLONE_ORIGINAL_HOME\")) {",
      "        setenv(\"APP_CLONE_ORIGINAL_HOME\", orig_home, 1);",
      "    }",
    ]

    // 排序让相同配置每次生成相同的源码，方便查看和比较。
    for key in variables.keys.sorted() {
      guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
        throw Failure.invalidVariable(key)
      }
      let value = variables[key]!.replacingOccurrences(
        of: "{{APP_CLONE_DATA_DIR}}", with: dataDirectory.path)
      guard !value.utf8.contains(0) else { throw Failure.valueContainsNul(key) }
      lines.append("    setenv(\(cString(key)), \(cString(value)), 1);")
    }

    if let appLanguage {
      guard !appLanguage.utf8.contains(0) else { throw Failure.valueContainsNul("AppleLanguages") }
      // 临时参数域不会写入应用或系统偏好；显式启动参数仍可覆盖分身的默认语言。
      lines.append(
        """
            @autoreleasepool {
                NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                NSMutableDictionary *arguments = [[defaults volatileDomainForName:NSArgumentDomain] mutableCopy];
                if (!arguments[@"AppleLanguages"]) {
                    arguments[@"AppleLanguages"] = @[@\(cString(appLanguage))];
                    [defaults setVolatileDomain:arguments forName:NSArgumentDomain];
                }
            }
        """)
    }

    // C 的 constructor 保证动态库加载时自动进入这个函数。
    // Swift 只生成这份文本，实际 setenv 在应用加载动态库时执行。
    return """
      #include <stdlib.h>
      \(appLanguage == nil ? "" : "#import <Foundation/Foundation.h>")

      __attribute__((constructor))
      static void appclone_env_init(void) {
      \(lines.joined(separator: "\n"))
      }

      """
  }

  /// 把 UTF-8 字节转成 C 字符串字面量，避免路径中的引号、换行等变成代码。
  private static func cString(_ value: String) -> String {
    let escaped = value.utf8.map { byte -> String in
      switch byte {
      case 34: return "\\\""
      case 92: return "\\\\"
      case 32...126: return String(UnicodeScalar(byte))
      default:
        // 固定三位八进制转义，后面的字符不会被误并入同一个转义序列。
        let octal = String(byte, radix: 8)
        return "\\" + String(repeating: "0", count: 3 - octal.count) + octal
      }
    }.joined()
    return "\"" + escaped + "\""
  }
}
