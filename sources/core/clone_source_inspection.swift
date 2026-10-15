/// 仅供一次操作使用的来源检查结果；不持久化，也不复用选择应用时的旧结果。
struct CloneSourceInspection: Sendable {
  let application: AppDescriptor
  /// 大小与磁盘检查均关闭时为 nil，此时没有遍历应用文件。
  let applicationBytes: Int64?
}
