/*
 * 对应 env_source.swift 的一组示例输入；路径、代理、语言均为示例配置
 * 仅用于 make env-dylib 开发验证；adv-clone 使用 env_source.swift 按配置生成源码
 */
#include <stdlib.h>

/* dyld 加载此动态库时自动执行；作为启动依赖时，在应用 main() 之前执行。 */
__attribute__((constructor))
static void appclone_env_init(void) {
    /* 用本项目的变量名保存启动时继承的 HOME。 */
    const char *orig_home = getenv("HOME");
    if (orig_home && !getenv("APP_CLONE_ORIGINAL_HOME")) {
        setenv("APP_CLONE_ORIGINAL_HOME", orig_home, 1);
    }

    /* 1 表示覆盖同名变量。修改只作用于当前进程的环境变量表。 */
    setenv("HOME", "/example/clone-data/home", 1);
    setenv("TMPDIR", "/example/clone-data/tmp", 1);

    /* 这些也只是变量：是否采用代理、语言配置，取决于应用的实现。 */
    setenv("HTTP_PROXY", "http://127.0.0.1:7890", 1);
    setenv("HTTPS_PROXY", "http://127.0.0.1:7890", 1);
    setenv("LANG", "zh_CN.UTF-8", 1);
    setenv("LC_ALL", "zh_CN.UTF-8", 1);
}
