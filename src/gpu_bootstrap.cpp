// gpu_bootstrap.cpp — LD_PRELOAD 垫片：把本进程的 Vulkan 驱动指向自定义的
// HAL 风格驱动目录（Turnip 等）。走 Android 官方「可更新 GPU 驱动」通道
// GraphicsEnv::setDriverPathAndSphalLibraries()，免 root。
//
// 用法:
//   CCODROID_GPU_DRIVER_DIR=<含 vulkan.<hw>.so 的目录> \
//   LD_PRELOAD=<本库> <程序 argv...>
#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>
#include <string>

namespace {

void setup() {
    const char* dir = getenv("CCODROID_GPU_DRIVER_DIR");
    if (dir == nullptr || *dir == '\0') return;

    void* h = dlopen("libgraphicsenv.so", RTLD_NOW | RTLD_LOCAL);
    if (h == nullptr) {
        fprintf(stderr, "[gpu-bootstrap] dlopen libgraphicsenv failed: %s\n", dlerror());
        return;
    }
    auto get_instance =
        reinterpret_cast<void* (*)()>(dlsym(h, "_ZN7android11GraphicsEnv11getInstanceEv"));
    using SetPathFn = void (*)(void*, const std::string&, const std::string&);
    auto set_path = reinterpret_cast<SetPathFn>(dlsym(
        h,
        "_ZN7android11GraphicsEnv30setDriverPathAndSphalLibrariesERKNSt3__112basic_stringIcNS1_11char_"
        "traitsIcEENS1_9allocatorIcEEEES9_"));
    if (get_instance == nullptr || set_path == nullptr) {
        fprintf(stderr, "[gpu-bootstrap] GraphicsEnv symbols not found\n");
        return;
    }
    set_path(get_instance(), std::string(dir), std::string());
    fprintf(stderr, "[gpu-bootstrap] driver path -> %s\n", dir);
}

struct Init {
    Init() { setup(); }
};
Init g_init;

}  // namespace
