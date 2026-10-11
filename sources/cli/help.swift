import appclonecore

enum CLIHelp {
  static var text: String { L10n.language == .zh ? zh : en }
  static var advClone: String { L10n.language == .zh ? advCloneZH : advCloneEN }

  static let advCloneZH = """
    用法：
      app-clone adv-clone <分身.app>
      app-clone adv-clone <分身.app> --data-dir <目录> [--proxy <地址>] [--locale <语言>]
      app-clone adv-clone <分身.app> --proxy http://127.0.0.1:7890
      app-clone adv-clone <分身.app> --locale zh_CN.UTF-8
      app-clone adv-clone <分身.app> --app-language zh-CN
      app-clone adv-clone <分身.app> --reset

    不带设置选项时查看当前配置；只修改传入的选项，保留其他配置。
    --data-dir 创建 home、tmp 子目录，设置分身的 HOME 和 TMPDIR。
    --proxy 设置 HTTP_PROXY 和 HTTPS_PROXY，只支持 HTTP/HTTPS 地址。
    --locale 设置 LANG 和 LC_ALL；--lang zh|en 控制本工具的输出语言。
    --app-language 设置分身界面语言（AppleLanguages），例如 zh-CN、en、ja。
    仅影响本次运行的偏好，不写入系统设置；显式 -AppleLanguages 启动参数优先。
    --reset 移除环境动态库及加载依赖，保留数据目录。
    --json 输出包含 environment 字段的分身记录；未启用时省略该字段。

    先退出分身再修改。设置时需要 Apple Command Line Tools 或 Xcode。
    仅操作本工具管理的分身；自动编译动态库、更新加载依赖并重新签名。
    下次启动生效。数据不会自动迁移，实际目录、代理和语言行为取决于应用。
    """

  static let advCloneEN = """
    Usage:
      app-clone adv-clone <clone.app>
      app-clone adv-clone <clone.app> --data-dir <directory> [--proxy <url>] [--locale <locale>]
      app-clone adv-clone <clone.app> --proxy http://127.0.0.1:7890
      app-clone adv-clone <clone.app> --locale zh_CN.UTF-8
      app-clone adv-clone <clone.app> --app-language zh-CN
      app-clone adv-clone <clone.app> --reset

    Without setting options, show the current configuration. Updates preserve omitted settings.
    --data-dir creates home and tmp subdirectories and sets HOME and TMPDIR for the clone.
    --proxy sets HTTP_PROXY and HTTPS_PROXY; only HTTP/HTTPS URLs are supported.
    --locale sets LANG and LC_ALL; --lang zh|en controls this tool's output language.
    --app-language sets the clone's interface language (AppleLanguages), e.g. zh-CN, en, or ja.
    Uses process-local preferences; explicit -AppleLanguages launch arguments take priority.
    --reset removes the environment library and its load dependency, preserving data directories.
    --json prints the clone record, including environment when enabled.

    Quit the clone before changes. Setting configuration requires Apple Command Line Tools or Xcode.
    Only managed clones are supported. The library is compiled, linked into the clone, and signed.
    Applies on the next launch. Data is not migrated; path, proxy, and locale behavior depends on the app.
    """

  static let zh = """
    app-clone \(AppCloneVersion.current) — macOS 应用分身工具

    用法：
      app-clone version
      app-clone doctor [--json]
      app-clone inspect <来源.app>
      app-clone clone <来源.app> --name <显示名称> [--icon <图片>]
      app-clone create（clone 的别名）
      app-clone list
      app-clone stats
      app-clone icon <分身.app> <图片>
      app-clone rename <分身.app> <新名称>
      app-clone adv-clone <分身.app> [--data-dir <目录>] [--proxy <地址>] [--locale <语言>] [--app-language <语言标识>]
      app-clone register
      app-clone verify <分身.app>
      app-clone remove <分身.app>

    --lang zh|en 指定语言，默认跟随终端或系统语言。
    --json 输出结构化结果。
    doctor 默认以文本显示工具状态和路径。
    --workspace <目录> 指定工作空间，分身、清单和统计独立存放。
    分身.app 可直接从 Finder 拖入，支持软链接；按路径操作时自动定位工作空间。
    默认副本目录：~/Library/Application Support/app-clone/apps。
    ~/Applications/app-clone 只放符号链接；register 可重建链接并向系统注册。
    clone、list、stats、register 未指定 --workspace 时使用默认工作空间。
    list 显示分身名称及完整路径，副本位于工作空间的 apps 子目录。

    图标支持 PNG、JPEG、ICNS。替换图标会重新签名。
    clone / create 不支持克隆系统应用；inspect 仍可查看其信息。
    rename 修改显示名称、应用包文件名和软链接，保留分身身份与图标。
    stats 按原应用统计当前工作空间的累计成功创建数和现存分身数；删除不复用序号。
    remove 只移除工具管理的应用副本，不删除应用用户数据。
    adv-clone 配置已有分身的环境变量和界面语言；运行 app-clone adv-clone 查看详细用法。
    """

  static let en = """
    app-clone \(AppCloneVersion.current) — macOS app cloning tool

    Usage:
      app-clone version
      app-clone doctor [--json]
      app-clone inspect <source.app>
      app-clone clone <source.app> --name <display-name> [--icon <image>]
      app-clone create (alias for clone)
      app-clone list
      app-clone stats
      app-clone icon <clone.app> <image>
      app-clone rename <clone.app> <new-name>
      app-clone adv-clone <clone.app> [--data-dir <directory>] [--proxy <url>] [--locale <locale>] [--app-language <tag>]
      app-clone register
      app-clone verify <clone.app>
      app-clone remove <clone.app>

    --lang zh|en selects the language; defaults to the terminal or system language.
    --json prints structured results.
    doctor shows tool status and paths as text by default.
    --workspace <directory> selects a workspace with its own clones, catalog, and statistics.
    Drag clone.app from Finder; symlinks are supported. Path commands locate the workspace automatically.
    Default clone directory: ~/Library/Application Support/app-clone/apps.
    ~/Applications/app-clone holds symlinks only; register rebuilds and registers them with macOS.
    clone, list, stats, and register use the default workspace unless --workspace is specified.
    list shows clone names and full paths. Copies are stored in the workspace's apps subdirectory.

    Icons support PNG, JPEG, and ICNS. Changing an icon re-signs the clone.
    clone / create do not support system apps; inspect can still display their information.
    rename changes the display name, bundle filename, and shortcut, preserving identity and icon.
    stats shows total creations and current clones per source app in this workspace; numbers are not reused.
    remove deletes only the managed app copy, preserving app user data.
    adv-clone configures a managed clone's environment and interface language; run app-clone adv-clone for details.
    """
}
