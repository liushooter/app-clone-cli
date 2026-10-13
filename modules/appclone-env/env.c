/*
 * 默认只保留初始化入口，不设置任何环境变量。
 * env 使用 env_source.swift 按传入配置生成初始化代码。
 */

/* dyld 加载此动态库时自动执行；作为启动依赖时，在应用 main() 之前执行。 */
__attribute__((constructor))
static void appclone_env_init(void) {
}
