import appclonecore

enum CLIHelp {
  static var text: String { L10n.language == .zh ? zh : en }

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
    rename 修改显示名称、应用包文件名和软链接，保留分身身份与图标。
    stats 按原应用统计当前工作空间的累计成功创建数和现存分身数；删除不复用序号。
    remove 只移除工具管理的应用副本，不删除应用用户数据。
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
    rename changes the display name, bundle filename, and shortcut, preserving identity and icon.
    stats shows total creations and current clones per source app in this workspace; numbers are not reused.
    remove deletes only the managed app copy, preserving app user data.
    """
}
