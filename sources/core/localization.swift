import Foundation

public enum AppLanguage: String, Sendable {
  case zh, en

  /// Explicit CLI selection takes precedence; C/POSIX and unsupported locales use English.
  public static func detect(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    preferredLanguages: [String] = Locale.preferredLanguages
  ) -> AppLanguage {
    let locale =
      ["LC_ALL", "LC_MESSAGES", "LANG"].compactMap { environment[$0] }
      .first { !$0.isEmpty } ?? preferredLanguages.first ?? "en"
    return locale.lowercased().split(whereSeparator: { "-_.@".contains($0) }).first == "zh"
      ? .zh : .en
  }
}

/// Compiled-in translations keep the CLI self-contained. No resource files or global mutation.
public enum L10n {
  @TaskLocal public static var language: AppLanguage = AppLanguage.detect()

  public enum Message: CaseIterable, Sendable {
    case linkOccupied
    case cancelled
    case outputFailed
    case timeout
    case commandFailed
    case registrationWarning
    case iconSize
    case iconFormat
    case iconDecode
    case iconEncoder
    case iconEncode
    case iconInvalid
    case iconCanvas
    case iconImageEncode
    case invalidAppFilename
    case noAvailableFilename
    case lockFailed
    case workspaceBusy
    case stateUnreadable
    case stateVersion
    case stateNumber
    case stateFilename
    case stateCountsMissing
    case stateCountsNegative
    case stateCountsMismatch
    case journalRecordMissing
    case targetExists
    case destinationExists
    case recoveryRequired
    case journalUnreadable
    case recoveryRevision
    case journalIdentityMissing
    case recoveryRenamedPath
    case recoveryRemovedPath
    case recoveryOriginalOccupied
    case recoveryTargetOccupied
    case recoveryRenameOccupied
    case journalTargetMissing
    case journalRenameIdentity
    case journalSamePath
    case recoveryOldPath
    case invalidPlist
    case invalidBundleID
    case invalidID
    case readDirectoryFailed
    case externalSymlink
    case ownershipMismatch
    case notApp
    case invalidBundle
    case notExecutable
    case unsupportedSystemApp
    case clonePathRequired
    case workspaceNotManaged
    case inspectProgress
    case cloneCountExhausted
    case bundleIDTooLong
    case renameProgress
    case removeProgress
    case linkCleanupWarning
    case removedProgress
    case iconProgress
    case copyProgress
    case identityProgress
    case attributesProgress
    case signProgress
    case verifyProgress
    case creationNumberMissing
    case installProgress
    case savedProgress
    case linkUpdateWarning
    case iconChanged
    case overlappingPaths
    case invalidName
    case nameConflict
    case notManaged
    case appRunning
    case unknownCommand
    case invalidOption
    case incompleteArguments
    case missingTools
    case toolAvailableLine
    case toolUnavailableLine
    case emptyList
    case emptyStats
    case originalIcon
    case customIcon
    case incompleteHistory
    case registrationFailed
    case invalidDirectoryPath
    case invalidFilePath
    case errorLine
    case statisticsLine
    case invalidLanguage
    case invalidProxy
    case invalidLocale
    case invalidAppLanguage
    case invalidDataDirectory
    case environmentConflict
    case environmentChanged
    case unsupportedMachO
    case resetEnvironmentUsage
    case environmentProgress
    case environmentDisabled
    case environmentEnabled
    case environmentDataLine
    case environmentProxyLine
    case environmentLocaleLine
    case environmentAppLanguageLine
  }

  public static func text(_ message: Message, _ arguments: String...) -> String {
    let template = translation(message, language: language)
    let parts = template.components(separatedBy: "{}")
    precondition(parts.count == arguments.count + 1, "Localization argument count mismatch")
    return parts.enumerated().map { index, part in
      index == 0 ? part : arguments[index - 1] + part
    }.joined()
  }

  static func translation(_ message: Message, language: AppLanguage) -> String {
    let pair: (zh: String, en: String)
    switch message {
    case .unsupportedSystemApp:
      pair = ("不支持克隆系统应用：{}", "Cloning system apps is not supported: {}")
    case .invalidProxy:
      pair = (
        "代理必须是有效的 HTTP/HTTPS 地址，可包含端口。",
        "Proxy must be a valid HTTP/HTTPS URL, optionally with a port."
      )
    case .invalidLocale:
      pair = (
        "语言格式无效，例如 zh_CN.UTF-8 或 en_US.UTF-8。",
        "Invalid locale; use a value such as zh_CN.UTF-8 or en_US.UTF-8."
      )
    case .invalidAppLanguage:
      pair = (
        "应用语言标识无效，例如 zh-CN、zh-Hant 或 en。",
        "Invalid app language tag; use a value such as zh-CN, zh-Hant, or en."
      )
    case .invalidDataDirectory:
      pair = (
        "数据目录不能覆盖用户主目录、应用或工作空间；工作空间内请放到 data 的子目录。",
        "Data directory must not overlap the user home, apps, or workspace; inside a workspace, use a child of data."
      )
    case .environmentConflict:
      pair = (
        "应用已包含非本工具管理的 libappclone_env.dylib，未覆盖。",
        "The app already contains an unmanaged libappclone_env.dylib; it was not overwritten."
      )
    case .environmentChanged:
      pair = (
        "分身的环境动态库或加载依赖已发生变化。", "The clone's environment library or load dependency has changed."
      )
    case .unsupportedMachO:
      pair = (
        "无法安全修改主程序的动态库依赖：格式、加密状态或头部余量不受支持。",
        "Cannot safely modify the executable's library dependency: unsupported format, encryption, or header space."
      )
    case .resetEnvironmentUsage:
      pair = (
        "--reset 不能和 --data-dir、--proxy、--locale、--app-language 同时使用。",
        "--reset cannot be combined with --data-dir, --proxy, --locale, or --app-language."
      )
    case .environmentProgress:
      pair = ("更新分身环境动态库和加载依赖", "Updating the clone environment library and load dependency")
    case .environmentDisabled:
      pair = ("未启用高级环境配置。", "Advanced environment configuration is disabled.")
    case .environmentEnabled:
      pair = (
        "已启用高级环境配置，下次启动分身时生效。", "Advanced environment configuration is enabled for the next launch."
      )
    case .environmentDataLine:
      pair = ("数据目录：{}（HOME=home，TMPDIR=tmp）", "Data directory: {} (HOME=home, TMPDIR=tmp)")
    case .environmentProxyLine:
      pair = ("HTTP/HTTPS 代理：{}", "HTTP/HTTPS proxy: {}")
    case .environmentLocaleLine:
      pair = ("应用语言环境：{}", "App locale: {}")
    case .environmentAppLanguageLine:
      pair = ("应用界面语言：{}", "App interface language: {}")
    case .linkOccupied:
      pair = ("应用入口已被占用，未覆盖：{}", "Application shortcut is occupied; nothing was overwritten: {}")
    case .cancelled:
      pair = ("操作已取消。", "Operation cancelled.")
    case .outputFailed:
      pair = ("无法创建命令输出文件。", "Cannot create the command output file.")
    case .timeout:
      pair = ("命令超时：{}", "Command timed out: {}")
    case .commandFailed:
      pair = ("{} 执行失败（{}）：\n{}", "{} failed ({}):\n{}")
    case .registrationWarning:
      pair = (
        "应用已保存，但系统注册失败（{}）；可运行 register 重试。",
        "The app was saved, but system registration failed ({}). Run register to retry."
      )
    case .iconSize:
      pair = ("图标文件必须非空且不超过 20 MB。", "The icon file must be nonempty and no larger than 20 MB.")
    case .iconFormat:
      pair = ("图标支持 PNG、JPEG 或 ICNS。", "Supported icon formats: PNG, JPEG, and ICNS.")
    case .iconDecode:
      pair = ("无法解码 PNG/JPEG 图标。", "Cannot decode the PNG/JPEG icon.")
    case .iconEncoder:
      pair = ("无法创建 ICNS 编码器。", "Cannot create the ICNS encoder.")
    case .iconEncode:
      pair = ("无法完成 ICNS 编码。", "Cannot finish encoding the ICNS icon.")
    case .iconInvalid:
      pair = ("ICNS 文件无效或没有可读取的图像。", "The ICNS file is invalid or contains no readable image.")
    case .iconCanvas:
      pair = ("无法创建图标画布。", "Cannot create the icon canvas.")
    case .iconImageEncode:
      pair = ("无法编码图标。", "Cannot encode the icon image.")
    case .invalidAppFilename:
      pair = ("应用包名称无效，未访问该路径。", "Invalid app bundle filename; the path was not accessed.")
    case .noAvailableFilename:
      pair = (
        "没有可用的应用包名称，未覆盖现有文件。", "No app bundle filename is available; existing files were preserved."
      )
    case .lockFailed:
      pair = ("无法锁定工作目录：{}", "Cannot lock the workspace: {}")
    case .workspaceBusy:
      pair = (
        "另一个操作正在使用此工作目录，请稍后重试。", "Another operation is using this workspace. Try again later."
      )
    case .stateUnreadable:
      pair = (
        "分身清单无法读取，已保留原文件：{}", "Cannot read the clone catalog; the original file was preserved: {}"
      )
    case .stateVersion:
      pair = ("不支持的清单版本或重复的分身 ID。", "Unsupported catalog version or duplicate clone IDs.")
    case .stateNumber:
      pair = ("分身编号与 Bundle ID 不一致。", "The clone number does not match the Bundle ID.")
    case .stateFilename:
      pair = ("清单中的应用包名称重复。", "The catalog contains duplicate app bundle filenames.")
    case .stateCountsMissing:
      pair = (
        "分身清单缺少创建统计，未重置计数。",
        "Creation statistics are missing from the catalog; counts were not reset."
      )
    case .stateCountsNegative:
      pair = ("累计创建数不能为负数。", "The total creation count cannot be negative.")
    case .stateCountsMismatch:
      pair = (
        "累计创建数与分身记录不一致，未重置计数。",
        "Creation counts do not match the clone records; counts were not reset."
      )
    case .journalRecordMissing:
      pair = ("操作缺少分身记录。", "The operation is missing a clone record.")
    case .targetExists:
      pair = ("目标已存在，未覆盖：{}", "The destination already exists; nothing was overwritten: {}")
    case .destinationExists:
      pair = ("目标已存在，未覆盖：{}", "The destination already exists; nothing was overwritten: {}")
    case .recoveryRequired:
      pair = (
        "操作中断且自动恢复未完成。保留了 pending.json 与暂存副本：{}",
        "The operation was interrupted and automatic recovery did not finish. pending.json and staged copies were preserved: {}"
      )
    case .journalUnreadable:
      pair = ("恢复记录无法读取，未进行任何替换：{}", "Cannot read the recovery journal; no files were replaced: {}")
    case .recoveryRevision:
      pair = (
        "清单与恢复记录的版本不一致，请保留文件进行检查。",
        "The catalog and recovery journal revisions differ. Keep the files for inspection."
      )
    case .journalIdentityMissing:
      pair = ("恢复记录缺少分身身份。", "The recovery journal is missing the clone identity.")
    case .recoveryRenamedPath:
      pair = (
        "改名前的路径又出现了文件，未自动清理。", "A file appeared at the old name; it was not removed automatically."
      )
    case .recoveryRemovedPath:
      pair = (
        "已删除分身的路径又出现了文件，未自动清理。",
        "A file appeared at the removed clone path; it was not removed automatically."
      )
    case .recoveryOriginalOccupied:
      pair = (
        "原路径已被占用，未自动覆盖。", "The original path is occupied; nothing was overwritten automatically."
      )
    case .recoveryTargetOccupied:
      pair = ("恢复目标已被占用。", "The recovery destination is occupied.")
    case .recoveryRenameOccupied:
      pair = (
        "改名目标已被占用，未自动覆盖。",
        "The rename destination is occupied; nothing was overwritten automatically."
      )
    case .journalTargetMissing:
      pair = ("恢复记录缺少目标身份。", "The recovery journal is missing the destination identity.")
    case .journalRenameIdentity:
      pair = ("改名恢复记录的分身身份不一致。", "Clone identities in the rename recovery journal do not match.")
    case .journalSamePath:
      pair = ("改名前后的路径相同。", "The paths before and after renaming are identical.")
    case .recoveryOldPath:
      pair = (
        "旧路径又出现了文件，未自动清理。", "A file appeared at the old path; it was not removed automatically."
      )
    case .invalidPlist:
      pair = ("无法读取应用属性列表：{}", "Cannot read the app property list: {}")
    case .invalidBundleID:
      pair = ("Bundle ID 不合法：{}", "Invalid Bundle ID: {}")
    case .invalidID:
      pair = ("分身 ID 必须是清单中的完整 UUID。", "The clone ID must be a complete UUID from the catalog.")
    case .readDirectoryFailed:
      pair = ("无法检查应用目录。", "Cannot inspect the app directory.")
    case .externalSymlink:
      pair = (
        "应用包含指向包外或失效的符号链接：{}",
        "The app contains a broken symlink or a symlink outside its bundle: {}"
      )
    case .ownershipMismatch:
      pair = ("分身身份不匹配，未修改该应用：{}", "Clone identity mismatch; the app was not modified: {}")
    case .notApp:
      pair = ("请选择 macOS .app 应用包。", "Choose a macOS .app bundle.")
    case .invalidBundle:
      pair = ("应用缺少有效的 Bundle ID 或可执行文件。", "The app is missing a valid Bundle ID or executable.")
    case .notExecutable:
      pair = ("应用主程序不可执行：{}", "The app executable cannot be run: {}")
    case .clonePathRequired:
      pair = (
        "请传入分身 .app 的路径，可直接从 Finder 拖入终端。",
        "Provide the path to a cloned .app. You can drag it from Finder into the terminal."
      )
    case .workspaceNotManaged:
      pair = (
        "该路径不是 app-clone 工作空间中的分身：{}", "This path is not a clone in an app-clone workspace: {}"
      )
    case .inspectProgress:
      pair = ("检查来源应用", "Inspecting the source app")
    case .cloneCountExhausted:
      pair = ("该应用的分身编号已达到上限", "The clone number for this app has reached its limit.")
    case .bundleIDTooLong:
      pair = (
        "原应用 Bundle ID 过长，无法追加分身编号和 UUID",
        "The source Bundle ID is too long to append a clone number and UUID."
      )
    case .renameProgress:
      pair = ("修改分身名称和应用包文件名", "Changing the clone display name and bundle filename")
    case .removeProgress:
      pair = ("移除工具管理的应用副本；不删除应用用户数据", "Removing the managed app copy; keeping app user data")
    case .linkCleanupWarning:
      pair = ("分身已移除，但链接清理失败：{}", "The clone was removed, but shortcut cleanup failed: {}")
    case .removedProgress:
      pair = ("已移除分身副本", "Clone removed")
    case .iconProgress:
      pair = ("生成多尺寸应用图标", "Generating app icons at multiple sizes")
    case .copyProgress:
      pair = ("复制应用到暂存目录", "Copying the app to the staging directory")
    case .identityProgress:
      pair = ("设置分身身份和名称", "Setting the clone identity and name")
    case .attributesProgress:
      pair = ("清理副本扩展属性", "Clearing extended attributes on the copy")
    case .signProgress:
      pair = ("重新签名副本", "Signing the copy")
    case .verifyProgress:
      pair = ("验证副本签名", "Verifying the copy signature")
    case .creationNumberMissing:
      pair = ("新分身缺少创建编号。", "The new clone is missing its creation number.")
    case .installProgress:
      pair = ("安装已验证的副本并保存清单", "Installing the verified copy and saving the catalog")
    case .savedProgress:
      pair = ("分身已保存", "Clone saved")
    case .linkUpdateWarning:
      pair = (
        "分身已保存，但应用入口更新失败：{}；可运行 register 重试",
        "The clone was saved, but updating its shortcut failed: {}. Run register to retry."
      )
    case .iconChanged:
      pair = (
        "已安装图标与清单不一致，未丢弃或覆盖自定义图标",
        "The installed icon differs from the catalog; the custom icon was preserved."
      )
    case .overlappingPaths:
      pair = ("来源应用和工作目录不能互相包含", "The source app and workspace must not contain each other.")
    case .invalidName:
      pair = (
        "名称需为 1–80 个字符，不能包含控制字符。", "Names must contain 1–80 characters and no control characters."
      )
    case .nameConflict:
      pair = ("已经存在同名分身：{}", "A clone with this name already exists: {}")
    case .notManaged:
      pair = ("当前工作空间没有管理此分身：{}", "This clone is not managed by the current workspace: {}")
    case .appRunning:
      pair = (
        "请先退出该分身，再修改图标、环境、名称或移除",
        "Quit the clone before changing its icon, environment, or name, or removing it."
      )
    case .unknownCommand:
      pair = (
        "未知命令：{}。运行 app-clone help 查看用法。", "Unknown command: {}. Run app-clone help for usage."
      )
    case .invalidOption:
      pair = ("未知、重复或缺少值的选项：{}", "Unknown, repeated, or missing-value option: {}")
    case .incompleteArguments:
      pair = (
        "{} 参数不完整。运行 app-clone help 查看用法。",
        "Invalid arguments for {}. Run app-clone help for usage."
      )
    case .missingTools:
      pair = ("部分系统工具不可用。", "Some required system tools are unavailable.")
    case .emptyList:
      pair = ("还没有分身。", "No clones yet.")
    case .emptyStats:
      pair = ("暂无分身创建记录。", "No clone creation history yet.")
    case .originalIcon:
      pair = ("原图标", "Original icon")
    case .customIcon:
      pair = ("自定义图标", "Custom icon")
    case .incompleteHistory:
      pair = (
        "（旧版历史不完整，累计为已知下限）", " (legacy history is incomplete; the total is a known lower bound)"
      )
    case .registrationFailed:
      pair = (
        "部分分身注册失败，应用已保留，可重试。",
        "Some clones could not be registered. The apps were preserved; you can retry."
      )
    case .toolAvailableLine:
      pair = ("[可用] {}", "[OK] {}")
    case .toolUnavailableLine:
      pair = ("[不可用] {}", "[UNAVAILABLE] {}")
    case .invalidDirectoryPath:
      pair = ("路径必须是真实目录，不能是符号链接：{}", "The path must be a real directory, not a symlink: {}")
    case .invalidFilePath:
      pair = ("路径必须是普通文件，不能是符号链接：{}", "The path must be a regular file, not a symlink: {}")
    case .errorLine:
      pair = ("错误：{}", "Error: {}")
    case .statisticsLine:
      pair = ("{} ({})  累计创建：{}  现存：{}{}", "{} ({})  Total created: {}  Current: {}{}")
    case .invalidLanguage:
      pair = ("--lang 需指定 zh 或 en，且只能使用一次。", "--lang requires zh or en and may only be used once.")
    }
    return language == .zh ? pair.zh : pair.en
  }
}
