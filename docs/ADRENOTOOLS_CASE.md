> 本文为子代理调研产物（只读调研：仅查阅网页、GitHub API 与 raw 源码，未在本机安装/下载/编译任何内容）；检索日期：2026-10-14。

# 免 root 高通 Adreno 自定义 GPU 驱动：机制、支持矩阵与 CLI 可行性调研

调研时间：2026-10-14。所有链接为可点击原文；版本号/日期均为来源标注。「未证实」= 未找到可靠证据。

---

## 一、机制拆解：AdrenoTools / libadrenotools

### 1.1 仓库现状（重要更正）

- 任务给的 `github.com/bylaws/adrenotools` **已不存在**（404，已验证 2026-10-14）。实际仓库是 **[bylaws/libadrenotools](https://github.com/bylaws/libadrenotools)**（370 star，BSD-2-Clause，最后代码提交 **2024-09-10**，此后基本休眠；[issue #24](https://github.com/bylaws/libadrenotools/issues/24) 有人在 2025-02 公开问维护状态，未解决）。
- 配套底层库 **[bylaws/liblinkernsbypass](https://github.com/bylaws/liblinkernsbypass)**（51 star）：README 明确「Android 9+ / Arm64；Android 8 和 arm32 稍作改动可支持」。

### 1.2 它到底做了什么（基于源码原文）

两层结构：

**(a) liblinkernsbypass —— 绕过 linker namespace 限制**
`android_linker_ns.cpp` 的做法（原文可查）：

1. **ARM64 机器码扫描**：`dlopen` 是 `__loader_dlopen` 的薄包装（第三参数传返回地址）。它在运行时扫描 `dlopen` 函数的机器码，找 BL 跳转指令（`sig == 0x25`），算出内部 `__loader_dlopen` 地址。扫描前会 `mprotect` 代码页为 RWX（注释：这是为了兼容某些设备的 `--X` 映射）。
2. **伪造 caller 绕过 namespace 检查**：以 **`dlopen` 的地址**作为 caller 参数调用 `loader_dlopen("ld-android.so", ...)`。源码注释原文：*"Passing dlopen as a caller address tricks the linker into using the internal unrestricted namespace letting us access libraries that are normally forbidden in the classloader namespace imposed on apps"*。由此拿到 `__loader_android_create_namespace`、`__loader_android_link_namespaces(_all_libs)`、`__loader_android_get_exported_namespace` 等隐藏符号（从 `ld-android.so` / `libdl_android.so` dlsym）。
3. **自建 namespace**：`linkernsbypass_link_namespace_to_default_all_libs()` 用 caller 伪造创建 "default_copy" 共享 namespace，再 `__loader_android_link_namespaces_all_libs` 把自定义 namespace 链到默认 namespace 的全部库。
4. **`namespace_dlopen_unique()`（libvulkan "替换"的核心）**：读 ELF 文件、**在内存/memfd 中改写 soname**（把 "lib..." 前缀用 3 位数字覆盖，如 `000...`），然后以 `ANDROID_DLEXT_USE_LIBRARY_FD|USE_NAMESPACE` 加载，从而**绕过 "同 soname 返回已加载实例" 的缓存**，得到第二份独立的 `libvulkan.so`。API<29 用临时目录文件，Q+ 用 `memfd_create`（`__NR_memfd_create=279`）。

**(b) libadrenotools —— 用 hook 把驱动加载重定向**

`src/driver.cpp` 的 `adrenotools_open_libvulkan()`：

1. 创建独立 namespace `"adrenotools-libvulkan"`（`SHA` 类型，`ld_library_path=hookLibDir`），链到默认 namespace；
2. 先预载 `libhook_impl.so`，再 `RTLD_GLOBAL` 载入 **`libmain_hook.so`**；
3. 最后 `linkernsbypass_namespace_dlopen_unique("/system/lib64/libvulkan.so", ...)` 在该 namespace 里加载一份**独立实例的系统 libvulkan**。

`src/hook/main_hook.c` 只做一件事：定义并导出 `android_dlopen_ext` / `android_load_sphal_library`（`RTLD_GLOBAL` + `-z global`，即变的 LD_PRELOAD）。系统 libvulkan 内部加载硬件驱动时调用的这两个符号被它**符号插桩拦截**。

`src/hook/hook_impl.cpp` 的 `hook_android_dlopen_ext()`：见到 `"vulkan."` 开头的文件名时，以 libvulkan 的 namespace 为 parent **创建子 namespace**（`ld_library_path=customDriverDir`、`default_library_path=hookLibDir`），links `libandroid.so`，预载 hook_impl，然后 `android_dlopen_ext(customDriverName)` 从自定义驱动目录加载驱动（如 `vulkan.ad0615.so` / `libvulkan_freedreno.so`）；找不到就 fallback 回系统驱动。即：**不是覆盖 /system/lib64/libvulkan.so 文件，而是让一份隔离的 libvulkan 实例去加载别的驱动**。

特性 flags（[priv.h](https://github.com/bylaws/libadrenotools/blob/master/include/adrenotools/priv.h)）：
- `ADRENOTOOLS_DRIVER_CUSTOM`：加载自定义驱动；
- `ADRENOTOOLS_DRIVER_FILE_REDIRECT`：拦截驱动 `fopen()`，把 `/data/.../adreno_config.txt` 等文件访问重定向到可写目录（`file_redirect_hook.c`）；
- `ADRENOTOOLS_DRIVER_GPU_MAPPING_IMPORT`：hook `gsl_memory_alloc_pure*`，用 `ioctl(KGSL_GPUOBJ_IMPORT)` 注入宿主内存（`gsl_alloc_hook.c`）。

此外 `libadrenotools` 直接 `open("/dev/kgsl-3d0", O_RDWR)` 做两件事：`adrenotools_set_turbo()`（`KGSL_PROP_PWRCTRL` 拉满频率）和 GPU 内存导入/分配——**即它自身就依赖 app 进程能打开 /dev/kgsl-3d0**（见第四节权限证据）。

### 1.3 官方 README/头文件里的硬约束（逐条）

| 约束 | 原文要点 | 来源 |
|---|---|---|
| Android 9+ / arm64 | README "Support: Android 9+, Arm64"；代码里 API<28 直接 `return nullptr`。Issue [#13](https://github.com/bylaws/libadrenotools/issues/13) 有 "none of the drivers work on android 9" 的报告（Android 9 实际体验差，标「存疑」） | [README](https://github.com/bylaws/libadrenotools/blob/master/README.md) |
| APK 必须 `useLegacyPackaging=true` | 头文件注释：*"The app MUST be packaged w/ useLegacyPackaging = true... otherwise hookLibDir won't be set correctly because Android expects to read the *.so directly from the apk"* —— 即 hook 库必须以**解压后的 JNI 库文件**形式存在于 `nativeLibraryDir` | [driver.h](https://github.com/bylaws/libadrenotools/blob/master/include/adrenotools/driver.h) |
| `hookLibDir` 必须是 `getApplicationInfo().nativeLibraryDir` | 传错会「返回非空句柄但 hook 失败→回退系统驱动或 0 设备」 | 同上 |
| `customDriverDir` 禁止在 sdcard | *"This path MUST NOT be on sdcard/storage... Otherwise you will get permission denied because dlopen() can't be done on *.so libraries that any random user or application can manipulate"* —— 必须放 app 私有目录（如 `/data/user/0/<pkg>/files/`） | 同上 |
| GPU 映射/预热 | `tmpLibDir` 仅 API<29 使用（Q+ 强制 memfd） | driver.cpp |
| 定位 | README FAQ：*"This library is not for installing into Android and is not for end users"*——每个 app 必须自己集成 | README |

### 1.4 驱动包格式 ADPKG（[tools/ADPKG.md](https://github.com/bylaws/libadrenotools/blob/master/tools/ADPKG.md)）

- 一个 zip = `meta.json` + 主驱动 `.so` + **所有依赖 .so（改过 soname，如 `notgsl.so`、`notadreno_utils.so`、`notdmabufheap.so`、`notllvm-glnext.so`）** + qtimapper-shim 系列（`android.hardware.graphics.mappershim.so` 等）。
- 依赖解析原理：驱动 namespace 的 `ld_library_path=customDriverDir` 优先解析自带依赖；**改 soname 是为了避免与系统已加载的同名库（libgsl.so 等）撞车**——ADPKG 原文：*"these must have their sonames altered if they wish to replace the system version of the library"*。
- 生成流程：`blob-patcher.py` 打补丁 → 手写 `meta.json` → 拷 qtimapper-shim（用途：在新驱动要求更高 `mapper ver` 时假装 5，兼容旧 gralloc/mapper）。
- 范例：Qualcomm v615 包装的官方描述就是 "Proprietary Vulkan driver for **Adreno 6xx and Adreno 7xx**"。

### 1.5 谁在用、怎么集成

| 项目 | 集成方式 | 证据 |
|---|---|---|
| **Winlator 系** | brunodev85 主线 README 致谢 "Mesa (Turnip/Zink/VirGL)"；**Bionic/cmod 分支**用 AdrenoTools 驱动包+libadrenotools（K11MCH1 的 `docs/winlator.md` 教你在 "Adrenotools GPU Drivers" 里 Install；Pipetto 的 wrapper 源码里硬编码了 `/data/data/com.winlator.cmod/files/...` 路径）；主线 11.x 的 Turnip 走容器内自有 loader（Bannerlator issue #18 称之为 "plain system Vulkan ICD"），v11.1 默认 Turnip 26.1.0 | [winlator](https://github.com/brunodev85/winlator)、[docs/winlator.md](https://github.com/K11MCH1/AdrenoToolsDrivers/blob/main/docs/winlator.md)、[Bannerlator#18](https://github.com/The412Banner/Bannerlator/issues/18) |
| **Skyline（已死）/ Strato** | libadrenotools 作者 bylaws 是 Skyline 开发者；K11MCH1 提供 "patched for Skyline" 构建，UI 路径 Settings→"GPU Driver Configuration"→Install（[docs/skyline.md](https://github.com/K11MCH1/AdrenoToolsDrivers/blob/main/docs/skyline.md)）；Skyline 2023 年因任天堂 DMCA 删源码（[README](https://github.com/skyline-emu/skyline)）。Strato 为后継项目，K11MCH1 README 标 "In the works" | K11MCH1 docs |
| **Yuzu 系（yuzu/Eden/Citron…）** | yuzu Android 原生有 GPU driver manager；K11MCH1 README 列 Eden、docs 有 citron.md，装法同 Yuzu（设置里导入驱动 zip） | [K11MCH1 README](https://github.com/K11MCH1/AdrenoToolsDrivers) |
| **Vita3K-Android** | README 直接链接 K11MCH1 驱动下载；app 内 "Add Custom Driver" | [Vita3K-Android](https://github.com/Vita3K/Vita3K-Android)、[docs/vita3k.md](https://github.com/K11MCH1/AdrenoToolsDrivers/blob/main/docs/vita3k.md) |
| **PPSSPP** | 仓库内置 `ext/libadrenotools` 子模块（镜像可查），有自己的 Adreno Driver Manager | [deepin 镜像](https://gitcode.com/deepin-community/ppsspp/tree/master/ext/libadrenotools)、[docs/ppsspp.md](https://github.com/K11MCH1/AdrenoToolsDrivers/blob/main/docs/ppsspp.md) |
| **Dolphin** | 设置 → Graphics → GPU driver → Install driver（选 zip） | [docs/dolphin.md](https://github.com/K11MCH1/AdrenoToolsDrivers/blob/main/docs/dolphin.md) |
| **ARMSX2（AetherSX2 继任）** | 设置 → Graphics → "GPU Driver Manager" → "+" | [docs/armsx2.md](https://github.com/K11MCH1/AdrenoToolsDrivers/blob/main/docs/armsx2.md) |
| **AetherSX2 原版（停更 2023）** | 本身不支持 Turnip 选择；社区补丁 [NetherSX2-Turnip](https://github.com/nckstwrt/NetherSX2-Turnip) 通过 **patch libemucore.so + shim libvulkan** 把系统 ICD 换成内置 Turnip（内置 a6xx/a8xx/A710 等多个版本） | NetherSX2-Turnip README |
| 其它 | bylaws 自己的 [vkcaps-adrenotools](https://github.com/bylaws/vkcaps-adrenotools)、[omalauncher PR "Offer Turnip GPU acceleration"](https://github.com/SimonSchubert/omalauncher/pull/67)、GameNative（GameNative/turnip-ci，已 archived） | 链接 |

---

## 二、Prebuilt 驱动仓库与支持矩阵

### 2.1 Turnip（Mesa freedreno Vulkan）prebuilt

**Mesa 官方没有 Android 二进制**：[download 页](https://docs.mesa3d.org/download.html)只发 tarball；[android 文档](https://docs.mesa3d.org/android.html)只教用 NDK 构建（含 `-Dplatforms=android -Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl` 的标准做法，这正是各类 AdrenoTools zip 的配方）。市场全靠第三方构建：

| 仓库 | 更新节奏（截至 2026-10） | 版本 | 形态 |
|---|---|---|---|
| [K11MCH1/AdrenoToolsDrivers](https://github.com/K11MCH1/AdrenoToolsDrivers) | 最新 release **v840 / v26.0.0-rc08，2026-01-14 / 01-08**；之后只剩自动化提交（最后 2026-10-13），无新 release | Turnip v24.0→v26.0-rc；Qualcomm v615–v849 | adpkg zip（`Turnip_v26.0.0_R8[_Gmem/_Sysmem].zip`、`turnip_a8xx.zip`、`Qualcomm_840_adpkg.zip`） |
| [The412Banner/Banners-Turnip](https://github.com/The412Banner/Banners-Turnip) | **每条 Mesa main 提交即出**（2026-10-14 当天已有 r2/r3/r4） | Mesa **26.3.0-dev**，Vulkan header 1.4.363 | 分 Standard(a6xx/a7xx)、A8xx 实验(810/812/825/829/830/840)、A710/720/722 实验、8 Gen 2 One UI 专用；还有 Wayland / glibc Linux ICD 变体 |
| [StevenMXZ/Adreno-Tools-Drivers](https://github.com/StevenMXZ/Adreno-Tools-Drivers) | GitHub Actions 每 2 周 | 跟随 Mesa（最新例 v26.2.0-R5） | 同一 builder 脚本 |
| [Weab-chan/freedreno_turnip-CI](https://github.com/Weab-chan/freedreno_turnip-CI) | 上游脚本（NDK **r29**、SDK 35） | — | 各仓库共同的上游来源 |
| [faux123/turnip-faux123-driver](https://github.com/faux123/turnip-faux123-driver) | 2026-09 | Adreno 8xx 修复（花屏、KGSL sync 崩溃） | Rootless via AdrenoTools |
| [whitebelyash/AdrenoToolsDrivers](https://github.com/whitebelyash/AdrenoToolsDrivers)、[Pipetto-crypto/Adrenotools-Drivers](https://github.com/Pipetto-crypto/Adrenotools-Drivers)、[tiagosouzacandido/…](https://github.com/tiagosouzacandido/AdrenoToolsTurnipDrivers) | 持续 | 各种 | 个人构建 |
| **Termux 包** | 已合入主线仓库 | `mesa` **26.2.5**（含 Turnip+zink）；`mesa-vulkan-icd-freedreno` 子包 | 见第三节 |

### 2.2 Turnip 支持的 Adreno 代际（2026-10 状态）

- 官方文档：[freedreno.rst](https://docs.mesa3d.org/drivers/freedreno.html) 原文 *"Turnip is a Vulkan 1.3 driver for Adreno 6xx GPUs"*（文档略滞后）；**源码为准**：`tu_device.cc` 中 `TU_API_VERSION = VK 1.4.x`，`props->apiVersion = (chip >= 7) ? 1.4 : 1.3` → **a7xx/a8xx 报 Vulkan 1.4，a6xx 报 1.3**（[源码](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/freedreno/vulkan/tu_device.cc)）。
- 设备表（[freedreno_devices.py](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/freedreno/common/freedreno_devices.py)）已含：a6xx 全系（含 6c Gen3 等新命名）、a7xx（704/722/735/753）、**a8xx：810/829/830/830v1/840/X2-85/X2-90**（830/829 有 KGSL chip_id 条目）。Mesa 26.1 加了 Adreno 810、issue 里在问 829（SD 8 Gen 5）。
- **A5xx（Adreno 506/509/512 等）：Turnip 永远不支持**。这不是"支持到什么程度"的问题——2025-11 mesa-dev 邮件列表 Rob Clark/Connor Abbott 专帖解释：a5xx 只有旧式 bindful descriptor，`VK_EXT_descriptor_indexing`/Vulkan 1.2 不可能，要重写驱动，「reward is not worth it」，真做也得是**另一个独立驱动**（[226559](https://lists.freedesktop.org/archives/mesa-dev/2025-November/226559.html)、[mail-archive 镜像](https://www.mail-archive.com/mesa-dev@lists.freedesktop.org/msg225079.html)）；文档明说 *"There are no plans to port to a5xx or earlier GPUs."*。a5xx 想要 Vulkan 只能用**厂商 blob**（通常 Vulkan 1.0/1.1）或系统原装驱动。freedreno **GL** 驱动倒是覆盖 a2xx–a6xx（含 a5xx）。
- **通用性**：Turnip 同一二进制天然覆盖整个 a6xx–a8xx 范围（运行时按 chip_id 选择，见 Banners-"Standard" 桶覆盖 6xx+7xx）；但因为 8xx 补丁、A710/722 补丁、三星 One UI UBWC 等仍在实验，**实践中按代际分桶**（a8xx 单独 zip、A710/720 单独 zip）。**专有驱动**：单 blob 常能跨相邻 2–3 代使用（实测：SD8Gen2/A740 系统驱动 0.676.76，直接用 0.805/0.840 可用），ADPKG 示例也写 "6xx and 7xx"；但无官方逐型号矩阵（「未证实官方保证」）。

### 2.3 Qualcomm 专有驱动版本段（K11MCH1 releases）

v615.77 / v676.x / v744.x / v757 / v768 / v777 / **v805 / v819.x / v837 / v840 / v842.6 / v849**（2023-12 → 2026-01）。`meta.json` 里 `minApi` 常见 27。K11MCH1 v26.0.0-rc08 说明：基于 Mesa 26.0.0-devel（Vulkan 1.4.335），**a8xx 支持 "super beta"、可能崩溃需重启**。

---

## 三、CLI 可用性（非 APK 进程、app uid）

### 3.1 系统 libvulkan 不能直接喂 ICD

- Android 的 libvulkan **不读 ICD JSON、不认识 `VK_ICD_FILENAMES`/`VK_DRIVER_FILES`**。它通过 `hw_get_module("vulkan")` 加载 `/vendor/lib64/hw/vulkan.<ro.hardware.vulkan>.so`（[AOSP driver.cpp](https://android.googlesource.com/platform/frameworks/native/+/refs/heads/main/vulkan/libvulkan/driver.cpp)，我的 grep 未发现任何 ICD/env 读取）。Khronos 文档原话：*"On Android, the discovery process focuses on searching for library files… The loader will load the driver via hw_get_module with the ID of 'vulkan'. Due to security policies in Android, none of this can be modified under normal use."*（[LoaderDriverInterface.md](https://chromium.googlesource.com/external/github.com/KhronosGroup/Vulkan-Loader/+/refs/tags/v1.2.197/docs/LoaderDriverInterface.md)）
- 所以 CLI 用自定义驱动只有两条路：**(A) 自带/依赖桌面版 Khronos loader（或干脆直接 dlopen 驱动）**；**(B) 用 libadrenotools 那套 hook**。

### 3.2 路线 A：Termux 现状（**已证明可行**）

- **`mesa` 包**（[build.sh](https://github.com/termux/termux-packages/blob/master/packages/mesa/build.sh)，版本 **26.2.5**）：`-Dvulkan-drivers=swrast,virtio,freedreno`（仅 arm/aarch64 加 freedreno）+ **`-Dfreedreno-kmds=msm,kgsl`**——一版同时支持 /dev/dri 和 /dev/kgsl-3d0 两套内核接口；gallium 侧带 **zink**。
- **`mesa-vulkan-icd-freedreno` 子包**（[subpackage.sh](https://github.com/termux/termux-packages/blob/master/packages/mesa/mesa-vulkan-icd-freedreno.subpackage.sh)）：安装 `lib/libvulkan_freedreno.so` + `share/vulkan/icd.d/freedreno_icd.*.json`，依赖 **`vulkan-loader-generic`**（Khronos loader，当前 **1.4.365**，[build.sh](https://github.com/termux/termux-packages/blob/master/packages/vulkan-loader-generic/build.sh)）；它替代了老的 `…-dri3` 包。x86 排除。
- 另有 `vulkan-loader-android` 包 = 直接把 NDK 的 Android loader 装进 `$PREFIX` 并链到 `/system/lib64/libvulkan.so`（给"用系统驱动"的场景）。
- **实测报告**：
  - [termux-packages#26526](https://github.com/termux/termux-packages/issues/26526)（A710 追踪帖）：初始 "device (gpu_id=710) is unsupported"，维护者更新到 Mesa 25.2 后，**2026-05 用户确认可用**：`vkmark` 显示 "Device Name: **Turnip Adreno (TM) 710**"，分数 1716，无花屏；Blender `--gpu-backend vulkan` 可用；**OpenGL(Zink) 仍有瑕疵**。设备 Android 15 / kernel 6.6.46-android15。
  - [termux-packages#19165](https://github.com/termux/termux-packages/issues/19165)：S24 Ultra(A750)/S21(S888) 上 glmark2(GL 4.6)、glmark2-es2(GLES 3.2)、glxgears、vkcube 经 Turnip+Zink 正常；**`MESA_VK_WSI_PRESENT_MODE=mailbox` 修掉 ES3.2 花屏**；vkmark 曾有 loader 版本相关报错。此帖也暴露了当时的 `wsi-termux-x11`/`tu_kgsl_export_dmabuf` 补丁维护难题。
- 结论：**给 CLI 的"通用高通驱动"首选就是 Turnip 以 ICD 形式加载**（Khronos loader + `VK_DRIVER_FILES`/默认 `$PREFIX/share/vulkan/icd.d`）。前提是调用方的 loader 是桌面版 loader（Termux 生态即是），或者程序**完全绕过 loader 直接 `dlopen(driver.so)` + `dlsym(vkGetInstanceProcAddr)`**（Mesa ICD 导出全部入口点，技术上可行；Ilan 的 vkproxy 也是这个思路）。

### 3.3 路线 B：在 Termux/CLI 里硬跑 libadrenotools（**已被打包验证，但有前提**）

- [termux-packages PR #32312](https://github.com/termux/termux-packages/pull/32312)（**2026-10-05 提出，2026-10-12 仍在更新，open**）：新增包 **`android-vulkan-icd-wrapper` + `libadrenotools`**。描述原文：*"It gives the ability to load the system Vulkan driver of any Android device as a normal Vulkan ICD for programs in Termux. This specific project also include AdrenoTools… it will use the selected driver instead. Like for projects like virglrenderer-android, compatibility varies between devices."* 这也**回答了任务的关键问题：非 APK 进程可以从 app 私有目录 dlopen 自定义驱动**（Termux 的 `$HOME`/`$PREFIX` 就行；sdcard 才不行）。
- 该 wrapper 是 [Pipetto-crypto/mesa](https://github.com/Pipetto-crypto/mesa) fork（tag v0.0.1），Mesa 里新增 `-Dvulkan-drivers=wrapper`。其 `wrapper_instance.c` 原文环境变量：
  `ADRENOTOOLS_DRIVER_PATH`（自定义驱动目录）、`ADRENOTOOLS_DRIVER_NAME`、`ADRENOTOOLS_HOOKS_PATH`（Termux 下默认 `$PREFIX/lib`）、`ADRENOTOOLS_REDIRECT_DIR`；然后调 `adrenotools_open_libvulkan(RTLD_NOW, flags, temp, hooks, path, name, redirect_dir, NULL)`。
- **Termux 为了在 CLI 里跑通 libadrenotools 打了两个补丁**（PR 文件）：① "avoid memfd when tmpdir set"（Q+ 允许强制用真实临时目录，否则默认 memfd）；② "fix non-aarch64 builds"（去掉 arm64-only 的 CMake 硬限制、补 arm/i386/x86_64 的 `memfd_create` 系统调用号）。上游**没有**官方支持这套用法。
- 用户实证：[leegao/bionic-vulkan-wrapper#204](https://github.com/leegao/bionic-vulkan-wrapper/issues/204)（2025-12 ~ 2026-01）：用户在 Termux 中设 `ADRENOTOOLS_DRIVER_PATH=$HOME/stery/`、`ADRENOTOOLS_DRIVER_NAME=vulkan.adreno.so`（新一带 Qualcomm 驱动）后称 *"works very well for me"*（hooks 路径该项给的是 `/system/lib64/`，与 `$PREFIX/lib` 并提——具体生效路径未逐一复现，「未证实」细节）。
- 另一条已被实测的 CLI 路线（不开源 hook）：[Ilan12346-maya/AdrenoToolsDrivers_termux](https://github.com/Ilan12346-maya/AdrenoToolsDrivers_termux) 用 `vulkan-loader-android` + 自建 `vkproxy.so` + 改 `libvulkan_wrapper.so` + 写 ICD JSON，让 Termux 里的程序加载 K11MCH1 专有驱动包；作者在 Redmagic 8s Pro (SD8Gen2/A740, 系统驱动 0.676.76) 上实测 0.805/0.840 可用；但**Turnip 与该方案互斥**、只验证了专有驱动。

---

## 四、/dev/kgsl-3d0、/dev/dri 权限与 Android 版本变化（带证据）

### 4.1 SELinux（AOSP 官方策略原文）

- `system/sepolicy/private/app.te` 第 393–394 行：**`allow { appdomain -isolated_app_all } gpu_device:chr_file rw_file_perms;`** ——**所有常规 app 域（含 untrusted_app，即 Termux/普通 app 进程）对 `gpu_device` 字符设备有读写权**。这是"app 进程能开 /dev/kgsl-3d0/渲染节点"的根源（[源码](https://android.googlesource.com/platform/system/sepolicy/+/refs/heads/main/private/app.te)）。
- 节点标签：AOSP 通用 file_contexts 只标了 `/dev/pvrsrvkm → gpu_device`；`/dev/dri/renderD128 → u:object_r:gpu_device:s0` 是**设备 sepolicy** 的惯例（AOSP goldfish 参考实现可查：[goldfish file_contexts](https://android.googlesource.com/device/generic/goldfish/+/de5cb704c78953e6c96fe7c1c52a0da678616225/sepolicy/common/file_contexts)）；kgsl 同理由厂商 sepolicy 标 `gpu_device`（未找到公开的 qcom 主线文件，标「未证实具体文件」）。
- **Android 16 新变化（重要）**：GPU 设备节点 **ioctl 白名单过滤**成为 AOSP 默认行为（OEM 可选，Pixel 6–9 Mali 已启用；示例 denial 就是 `untrusted_app_25 ... ioctl /dev/mali0 gpu_device`）。对 Adreno 自定义驱动的影响：若 OEM 启用且内核/KGSL 新增 ioctl 未同步进 allowlist，新驱动可能被拒。[Android 16 行为变更](https://developer.android.com/about/versions/16/behavior-changes-16)。

### 4.2 节点权限（ueventd 实测配置）

- AOSP `system/core/rootdir/ueventd.rc`：**`/dev/dri/* 0666 root graphics`**（[源码](https://android.googlesource.com/platform/system/core/+/refs/heads/main/rootdir/ueventd.rc)）。
- Pixel 3 官方设备：[ueventd.hardware.rc](https://android.googlesource.com/device/google/crosshatch/+/refs/heads/main/ueventd.hardware.rc)：**`/dev/kgsl-3d0 0666 system system`**。老设备/其他 OEM 例子同样普遍 0666（root/system 属组不同）。
- 与"实测报告"一致：Termux 用户能在 Android 15 上跑通 Turnip(#26526)、能在 Termux 中加载专有驱动(#204)、PR #32312 声称可把"系统 Vulkan 驱动"给任意 Termux 程序用——都要求这些节点可访问。**未找到任何 Termux/app 场景 "kgsl-3d0 permission denied" 的实测报告**（搜到的全是 Ubuntu Touch/LXC 或内核开发场景）。个别 OEM 可能有更严的厂商 SELinux（「未证实」）。

### 4.3 版本差异（有据可查的部分）

| Android 版本 | 相关事实 | 来源 |
|---|---|---|
| 9 | libadrenotools 声称 9+，但 issue #13 "none of the drivers work on android 9"；linkernsbypass 支持 9+ | libadrenotools issues |
| 10 (API 29) | Q+ 有 memfd（libadrenotools 走 memfd 路径）；**社区实测报告：SD845/Android 10 上 adrenotools hook 静默失败**（回退系统驱动），同项目改用 "direct ICD" 后可用；社区另有"Android 10 需特定 turnip-v12/24.x"的说法 | [Bannerlator#18](https://github.com/The412Banner/Bannerlator/issues/18)（2026-06）；后者出自论坛/指南，标「未证实」 |
| 11+ | 同一报告称 adrenotools hook "needs ~Android 11+"（设备相关，非官方结论） | 同上 |
| 14/15 | 未发现 libadrenotools/Turnip 被系统变化破坏的报告；Termux 用户在 A15 上正常（#26526, 2026-05） | 同上 |
| 16 | 16KB 页转默认推进 + GPU ioctl 过滤（见上）；libadrenotools 修过 NDK27 下 `PAGE_SIZE` 未定义的 16KB 兼容编译问题（[issue #21](https://github.com/bylaws/libadrenotools/issues/21)） | Android 官方文档 |
| 16KB 页 | 官方要求：**NDK r28+ 默认 16KB 对齐**；r27- 需 `-Wl,-z,max-page-size=16384`；非对齐 .so 在 16KB 设备上可能无法加载（有 app 级 backcompat 开关）。第三方 Turnip 构建用 **NDK r29**，默认合规；**老 Qualcomm 专有 blob（4KB 对齐）在 16KB 设备上的 dlopen 失败报告未找到（未证实）** | [page-sizes 文档](https://developer.android.com/guide/practices/page-sizes) |

---

## 五、已知坑与失败案例清单

1. **Android 10 / 老设备 hook 静默失败**（Bannerlator #18，2026-06）：adrenotools 路线回退系统驱动且无报错；改用 direct-ICD 路线解决。同帖里 direct-ICD 的 "turnip-26.1.0" 选项在一个 SD845 用户机上直接闪退（仍 WIP）。
2. **sdcard 不能 dlopen .so**（libadrenotools 头文件原文）：必须 app 私有目录。
3. **soname 冲突**：新驱动依赖必须改 soname 打包（`notgsl.so` 等）；否则被系统已加载库顶掉。qti mapper 版本不匹配需要 mapper-shim（ADPKG）。
4. **A710/720 与 GMEM**：Winlator 下建议 `TU_DEBUG=sysmem`；三星 One UI UBWC 问题设 `FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1`（K11MCH1 rc08 说明 + Banners-Turnip notes）。
5. **a8xx 仍实验**：K11MCH1 "very beta and hacky，可能崩溃需重启"；Banners-Turnip 单开 A8xx 桶（810/812/825/829/830/840）+ 独立补丁。
6. **Zink 的差距**：Termux 上 Turnip+Zink 可跑 GL 4.6（glmark2），但 ES3.2/GLES 有明显花屏史（#19165）；A710 用户 2026-05 仍报 "OpenGL has artifacts, Vulkan OK"（#26526）。Winlator/glibc 场景 "Zink still unusable"（Bannerlator 讨论，2026）。
7. **A750/新代际前期不稳定**：#19165 记录过 device lost / "Too many open files" / vkmark loader 版本 bug 等，随 Mesa/Termux 更新缓解。
8. **"a6xx 用不了 Turnip 25.x+"**：社区指南反复出现（见 [tech-insider 等](https://tech-insider.org/fr/adrenotools-booster-emulateurs-android-2026/)），与 Mesa 官方支持清单矛盾（新 Mesa 仍含 a6xx）。**标「存疑/未证实」**，更可能是旧内核/旧 Android 特定问题。
9. **libadrenotools 上游休眠**（2024-09 最后提交）；Termux 侧不得不自带补丁（memfd/非 aarch64/打包）；wrapper PR 仍 open。
10. **winlator 变体分裂**：主线 loader 路线（任意 Android 版本可用）vs Bionic/cmod adrenotools 路线，用户混用容易踩"驱动装了没效果"的坑（#18 根因即此）。

---

## 六、对「通用、免 root、给 CLI 用」的结论

**结论 1（可行，推荐路线）**：**Turnip 走"桌面 Vulkan loader + ICD JSON"是当前唯一被反复实证、免 root、可在 app uid CLI 里工作的"通用高通驱动"方案**。证据：Termux `mesa-vulkan-icd-freedreno`（arm/aarch64，Mesa 26.2.5，含 kgsl+msm 双后端）+ `vulkan-loader-generic`，用户在 A710/Android 15 实测 vkmark 1716 分（2026-05）。适用于 **a6xx 及以上**；同一二进制覆盖多代（a6xx=1.3，a7xx/a8xx=1.4），a8xx 需用实验变体。
- 落地要点：驱动与 JSON 放 app 私有目录（如 `…/files/usr/share/vulkan/icd.d/`）；用 Khronos loader（`VK_DRIVER_FILES`/默认搜索路径）；WSI 要匹配——**headless/离屏不需要 WSI**，要出窗则选 `platforms=android`（ANativeWindow）或 `platforms=x11`（Termux:X11）的构建；**绝不要假设系统 libvulkan 会读 ICD**。

**结论 2（可行但有条件）**：**专有 Qualcomm 驱动（含跨代"更高级号"）可在 CLI 使用**，但必须经由 wrapper 类组件（Pipetto wrapper / vkproxy / bionic-vulkan-wrapper），因为要处理：SPIR-V 补丁（`OpConstantComposite→OpSpecConstantComposite`、去 ClipDistance）、依赖与 soname、mapper-shim。Termux 有实证（#204、Ilan 仓库），但逐设备兼容性差异大（PR #32312 原文警告）。

**结论 3（可行但有风险）**：**libadrenotools 的 hook 路线可以离开 APK 语境**——Termux 已把它打成包，hook 库放 `$PREFIX/lib`、驱动放任意私有目录即可运行（wrapper 源码默认值 + 用户实测）；代价是：上游不保证（README 明确面向 app 开发者，要求 APK `useLegacyPackaging=true`/`nativeLibraryDir`）、上游休眠、需要在你的环境下自己补 memfd/架构/x86 之类补丁，且 **Android 10 有静默失败实报**。

**结论 4（不可行/不存在）**：**A5xx（Adreno 506/509/512 等）没有 Turnip，将来也不会有**（2025-11 官方邮件列表定论）。a5xx 只能依赖系统/厂商 blob（Vulkan 1.0/1.1）。所以"一个驱动覆盖所有高通 GPU（含 a5xx）"的说法**不成立**；"通用"的合理边界 = **a6xx–a8xx 用 Turnip，a5xx 另走专有驱动**。

**结论 5（权限面）**：在 app uid（untrusted_app 域）下访问 `/dev/kgsl-3d0`、`/dev/dri/*` **策略上是被允许的**（AOSP `app.te` 明确 allow + ueventd 0666），实测层面未发现阻断报告；主要不确定性在个别 OEM 厂商策略、Android 16 的 GPU ioctl 过滤（OEM 可选）与 16KB 页设备上的旧 blob 对齐。

**对 cc.codroid 这类"通用高通 GPU 驱动"组件的具体建议**（基于以上证据，非实测）：
1. 首发只做 **Turnip-on-ICD** 的 CLI 路径（形态照抄 Termux 两个包：mesa freedreno ICD + generic loader；或自带 loader/直接 dlopen 驱动）。这满足"通用、免 root、CLI 可用"的 90% 场景。
2. 需要专有驱动时，参考 Pipetto wrapper 模式做一个 app 内 wrapper（它已验证在 Termux 环境可行），用 `ADRENOTOOLS_*` 风格环境变量选择驱动；a5xx 单独提示"仅系统驱动"。
3. 不要在 CLI 场景依赖系统 libvulkan；也不要把 adrenotools hook 当作第一实现（设备差异 + 上游休眠 + Android 10 失败报告）。
4. 监测点：Mesa 26.3/27 的 a8xx 成熟度、Termux PR #32312（CLI 下 adrenotools 的官方打包动态）、Android 16 ioctl 过滤的 OEM 采用率、16KB 页设备的专有 blob 表现。

---

### 附：主要来源清单（按章节）

- 机制：[libadrenotools](https://github.com/bylaws/libadrenotools)、[driver.h](https://github.com/bylaws/libadrenotools/blob/master/include/adrenotools/driver.h)、[driver.cpp](https://github.com/bylaws/libadrenotools/blob/master/src/driver.cpp)、[hook_impl.cpp](https://github.com/bylaws/libadrenotools/blob/master/src/hook/hook_impl.cpp)、[ADPKG.md](https://github.com/bylaws/libadrenotools/blob/master/tools/ADPKG.md)、[liblinkernsbypass](https://github.com/bylaws/liblinkernsbypass)、[AdrenoToolsTest](https://github.com/darksylinc/AdrenoToolsTest)
- Turnip/Mesa：[freedreno 文档](https://docs.mesa3d.org/drivers/freedreno.html)、[android 构建文档](https://docs.mesa3d.org/android.html)、[tu_device.cc](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/freedreno/vulkan/tu_device.cc)、[freedreno_devices.py](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/freedreno/common/freedreno_devices.py)、[a5xx 邮件列表 2025-11](https://lists.freedesktop.org/archives/mesa-dev/2025-November/226559.html)
- 驱动仓库：[K11MCH1](https://github.com/K11MCH1/AdrenoToolsDrivers)、[Banners-Turnip releases](https://github.com/The412Banner/Banners-Turnip/releases)、[StevenMXZ](https://github.com/StevenMXZ/Adreno-Tools-Drivers)、[Weab-chan CI](https://github.com/Weab-chan/freedreno_turnip-CI)
- Termux/CLI：[mesa build.sh](https://github.com/termux/termux-packages/blob/master/packages/mesa/build.sh)、[freedreno 子包](https://github.com/termux/termux-packages/blob/master/packages/mesa/mesa-vulkan-icd-freedreno.subpackage.sh)、[loader-generic](https://github.com/termux/termux-packages/blob/master/packages/vulkan-loader-generic/build.sh)、[PR#32312](https://github.com/termux/termux-packages/pull/32312)、[PR#28671](https://github.com/termux/termux-packages/pull/28671)、[#26526](https://github.com/termux/termux-packages/issues/26526)、[#19165](https://github.com/termux/termux-packages/issues/19165)、[Ilan 仓库](https://github.com/Ilan12346-maya/AdrenoToolsDrivers_termux)、[zink-xlib-termux](https://github.com/alexvorxx/zink-xlib-termux)、[bionic-vulkan-wrapper#204](https://github.com/leegao/bionic-vulkan-wrapper/issues/204)
- Android 加载器/策略：[AOSP libvulkan driver.cpp](https://android.googlesource.com/platform/frameworks/native/+/refs/heads/main/vulkan/libvulkan/driver.cpp)、[Khronos LoaderDriverInterface（Android 驱动发现）](https://chromium.googlesource.com/external/github.com/KhronosGroup/Vulkan-Loader/+/refs/tags/v1.2.197/docs/LoaderDriverInterface.md)、[app.te](https://android.googlesource.com/platform/system/sepolicy/+/refs/heads/main/private/app.te)、[ueventd.rc](https://android.googlesource.com/platform/system/core/+/refs/heads/main/rootdir/ueventd.rc)、[crosshatch ueventd](https://android.googlesource.com/device/google/crosshatch/+/refs/heads/main/ueventd.hardware.rc)、[goldfish file_contexts](https://android.googlesource.com/device/generic/goldfish/+/de5cb704c78953e6c96fe7c1c52a0da678616225/sepolicy/common/file_contexts)、[Android 16 行为变更](https://developer.android.com/about/versions/16/behavior-changes-16)、[16KB 页文档](https://developer.android.com/guide/practices/page-sizes)
- 项目集成：[Winlator](https://github.com/brunodev85/winlator)、[Bannerlator#18](https://github.com/The412Banner/Bannerlator/issues/18)、[Skyline](https://github.com/skyline-emu/skyline)、[Strato](https://github.com/strato-emu/strato)、[Vita3K-Android](https://github.com/Vita3K/Vita3K-Android)、[NetherSX2-Turnip](https://github.com/nckstwrt/NetherSX2-Turnip)、K11MCH1 `docs/*.md`

（本次调研全程只读，未在本机安装、下载或编译任何内容；「存疑/未证实」处已在文中逐条标注。）
