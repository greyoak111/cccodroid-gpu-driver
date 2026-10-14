> 说明：本文件为子代理（Claude Code 调研任务）产出的「Blender on Android」调研报告，检索日期 2026-10-14（UTC）。内容为纯网页/GitHub API 只读调研，原文保留、未做删改。

---

# 「Blender on Android / Blender CLI on Android」调研报告

**检索日期：2026-10-14（UTC）**。所有 star 数、提交时间为该日实测（GitHub API / 仓库页面）。未在本机安装、下载或编译任何东西；仅读取网页与 GitHub API（curl 直读 + WebFetch）。凡不确定处均标注「未证实」。

**核心结论速览**

1. **不存在**一个单独名为「Blender CLI on Android」的知名仓库（截至检索日在 GitHub 搜索 `blender android/termux/headless/apk` 均未发现以 CLI 为主线的项目）。Android 上跑 Blender 实际有 4 条路线：官方/社区 APK 原生端口、Termux 原生包（TUR）、proot/chroot 内跑 Linux arm64 Blender、以及 Hangover Wine 跑 Windows arm64 Blender。见 [GitHub 搜索结果（检索式 blender+android）](https://github.com/search?q=blender+android&type=repositories)。
2. **GPU 方面唯一有完整工程化方案的现状**：UI/EEVEE/Workbench 走 Vulkan（APK 端口，vendor 驱动或 Mesa Turnip），或 Termux 下 OpenGL→Zink→Vulkan/Turnip；**Cycles 在所有 Android 路线里都是纯 CPU 渲染**（Cycles 自 Blender 3.0 起已移除 OpenCL，见 [Blender 3.0 release notes](https://projects.blender.org/blender/blender-developer-docs/raw/branch/main/docs/release_notes/3.0/cycles.md)）。
3. 免 root 加载 Turnip 的两条成熟思路：**libadrenotools**（APK 内从自己的 nativeLibraryDir 加载 `libvulkan_turnip.so`，[bylaws/libadrenotools](https://github.com/bylaws/libadrenotools)，仓库自述 "rootless Adreno GPU driver modifications/replacements"）和 **Termux 包**（`mesa-vulkan-icd-freedreno` + `MESA_LOADER_DRIVER_OVERRIDE=zink`）。

---

## 1. 项目清单

| 项目 | URL / 作者 | 类型 | Star | 最后提交（2026-10-14 实测） | 许可证 |
|---|---|---|---|---|---|
| 官方 Blender Android 分支 | [blender/blender @android](https://github.com/blender/blender/tree/android)（镜像；官方仓库在 [projects.blender.org](https://projects.blender.org/blender/blender)） | 源码分支（构建系统/依赖准备） | n/a | 2026-10-09（sha 258eef0） | GPL（Blender 本体） |
| 官方 demo APK（BCON26） | [blender.org/download/demo/tablet](https://www.blender.org/download/demo/tablet/) | APK（实验 demo） | n/a | 2026-09 发布（会议 09-23~25） | GPL |
| simfeo/blender（含站点 blenderandroid.github.io） | [github.com/simfeo/blender](https://github.com/simfeo/blender) | APK（arm64、Vulkan） | 46 | 2026-09-26 | GPLv3（Blender） |
| Wanderson-Magalhaes/blender_for_android | [github.com/Wanderson-Magalhaes/blender_for_android](https://github.com/Wanderson-Magalhaes/blender_for_android) | APK（S24 Ultra 调优 fork） | 50 | 2026-09-01 | GPLv3，作者声明不再维护 |
| TUR Termux 包 blender5 | [tur-on-device/blender5](https://github.com/termux-user-repository/tur/tree/master/tur-on-device/blender5) | Termux 包（on-device 编译） | 仓库 980 | 版本 5.2.2（2026-10-01 bump PR [#2857](https://github.com/termux-user-repository/tur/issues/2857)） | GPL-3.0-or-later（blender.org 建议） |
| TUR Termux 包 blender4 | [tur-on-device/blender4](https://github.com/termux-user-repository/tur/tree/master/tur-on-device/blender4) | Termux 包 | 同上 | 版本 4.5.14 | 同上 |
| dshawshank/APP-android_arm64（旧端口，含 4 个仓库） | [github.com/dshawshank/APP-android_arm64](https://github.com/dshawshank/APP-android_arm64) | APK（Blender 3.6 时期，GLES） | 682 | 2025-08-07 | GPL-2.0 |
| gamextra4u/Blender-on-Termux | [github.com/gamextra4u/Blender-on-Termux](https://github.com/gamextra4u/Blender-on-Termux) | 脚本 + Wine（Windows arm64 Blender） | 6 | 2024-12-01 | MIT |
| lfdevs/blender-linux-arm64 | [github.com/lfdevs/blender-linux-arm64](https://github.com/lfdevs/blender-linux-arm64) | CI 构建 Linux arm64 二进制（proot/chroot 用） | 15 | 2026-05-15 | 未声明 |
| 驱动基础设施：by laws/libadrenotools | [github.com/bylaws/libadrenotools](https://github.com/bylaws/libadrenotools) | 库 | 370 | 2024-09-10 | 见仓库 |
| 驱动来源：whitebelyash/AdrenoToolsDrivers | [github.com/whitebelyash/AdrenoToolsDrivers](https://github.com/whitebelyash/AdrenoToolsDrivers) | 预编译 Turnip for AdrenoTools（偏 A8XX） | 468 | 2026-09-19 | 见仓库 |
| 驱动来源：MatrixhKa/mesa-turnip | [github.com/MatrixhKa/mesa-turnip](https://github.com/MatrixhKa/mesa-turnip) | 预编译 Turnip（proot/chroot 用，24.1.0） | 1 | 2025-03-05 | 见仓库 |
| 杂项（未证实价值） | [Tintedfireglass/blender-android](https://github.com/Tintedfireglass/blender-android)（23★，2022）、[Google61/blender-termux](https://github.com/Google61/blender-termux)（3★，WIP）、[nerdynoob223/blender-2.79-termux](https://github.com/nerdynoob223/blender-2.79-termux)、[werdio325-png/blender-android](https://github.com/werdio325-png/blender-android)、[46Neon/blender-app](https://github.com/46Neon/blender-app)、[system32ovo/BlenderForAndroid](https://github.com/system32ovo/BlenderForAndroid)、[Artist128 镜像](https://github.com/Artist128/Blender-for-android-v4.0.0.0-alpha-)（22★，称 dshawshank 或已停止维护，未证实） | 多为 0★/疑似教程或复刻 | — | — | — |

---

## 2. 构建 / 运行方式（逐项目）

### 2.1 官方 Blender Android（Blender Foundation）

- 官方 GitHub 镜像存在 `android` 分支，最新提交 2026-10-09 "Cleanup: Deps: Clarify that the ISPC cross-compilation patch only affects NDK sysroot on macOS"（API 中 commit author 为 Jonas Holzman；网页显示提交者账号 Brainzman）；关键提交如 2026-10-05 的 "Android: Fix cross-compilation from Linux and Windows and add x86_64 ABI support"（提交页：[blender/blender commits/android](https://github.com/blender/blender/commits/android)）。
- 该分支**已包含官方预编译依赖子模块** `lib/android_arm64`（`.gitmodules` 指向 [projects.blender.org/blender/lib-android_arm64.git](https://projects.blender.org/blender/lib-android_arm64)）（2026-10-14 实测 raw 200）。
- 但**公开镜像里还没有 GHOST Android 后端和 APK 打包文件**：`build_files/android/*`、`intern/ghost/intern/GHOST_SystemAndroid.cc`、`build_files/cmake/platform/platform_android.cmake` 均 404（2026-10-14 实测）。有 "Gradle Staging" 相关清理提交（如 a7ce24a3、5c5ddfad），说明官方正在搭 Android 打包管线。[blender/blender tree/android](https://github.com/blender/blender/tree/android)
- 发布物：BCON26（2026-09-23~25，阿姆斯特丹）Jonas Holzman 演讲 "Porting Blender to Android"（[conference.blender.org/2026/presentations/4291](https://conference.blender.org/2026/presentations/4291/)），会场上发布**官方实验 demo APK**：下载入口 [blender.org/download/demo/tablet](https://www.blender.org/download/demo/tablet/)（确认存在；直链为 mirror.blender.org/demo/tablet；第三方报道称为 `blender-demo-bcon2026.apk`，[Marco's Box 报道](https://www.marcosbox.com/2026/09/27/blender-android-apk-ufficiale-tablet-3d/)）。目标 2027 上半年正式发布（[code.blender.org BCON26 talks](https://code.blender.org/2026/10/bcon26-talks-by-blender-developers/)、[80.lv Wacom 实机报道](https://80.lv/articles/see-blender-5-3-running-on-wacom-android-tablet)）。
- GPU 要求官方**尚未公布**；官方（Jeroen Bakker 发起）在 devtalk 征集 Android 平板 Vulkan 能力数据（用 Vulkan Caps Viewer 上传 GPU 信息），见 [80.lv 报道](https://80.lv/articles/blender-seeks-feedback-from-android-13-tablet-users)。

### 2.2 simfeo/blender（当前最完整的社区 APK 端口）

- 仓库：[github.com/simfeo/blender](https://github.com/simfeo/blender)，是 **blender/blender 的 fork**（`android` 分支，46★，最新提交 2026-09-26，作者 idimus/simfeo）。网站与下载：[blenderandroid.github.io](https://blenderandroid.github.io/)。
- 构建文档（关键文件）：[build_files/android/BUILDING.md](https://github.com/simfeo/blender/blob/android/build_files/android/BUILDING.md)、[env.sh](https://github.com/simfeo/blender/blob/android/build_files/android/env.sh)、[build_apk.sh](https://github.com/simfeo/blender/blob/android/build_files/android/build_apk.sh)、[build.py](https://github.com/simfeo/blender/blob/android/build_files/android/build.py)、[apk/package.sh](https://github.com/simfeo/blender/blob/android/build_files/android/apk/package.sh)。
- 要点（BUILDING.md 原文归纳）：
  - 目标 Android 12+（minSdk 31，target 34），**arm64 only**；依赖来自官方 Android 端口的预编译集 `lib/android_arm64` 子模块，**NDK 必须是 r30 beta1**（"The NDK must be r30 ... An older NDK produces an APK that installs and then dies in `dlopen`"）；
  - 一条命令构建：`build_files/android/build.py full --install --run`（full/lite 两套 feature set，见 `android_features_{common,full,lite}.cmake`；lite 去掉 Cycles/视频/USD 等，保留 EEVEE/Workbench/Python）；
  - APK 首次启动解包 ~100MB runtime 到 `<filesDir>/blender/5.3/`；无 OpenGL 回退，**Rendering is Vulkan**；Vulkan 1.1 设备走 render-pass fallback；
  - 已知的 bionic/NDK 兼容问题与补丁：`compat/` 提供 NDK libc++ 缺失的 `std::atomic_ref` polyfill；libpython 以 `libpython3_13_bin.so` 放进 native lib 目录（因 API 29+ 数据目录 noexec）；用 `source/creator/symbols_unix.map` 做符号版本脚本。
- 版本/发布（[Releases 页](https://github.com/simfeo/blender/releases)）：android-alpha-1（2026-08-07，166MB full）→ alpha-2（09-06）→ alpha-3（09-07，加 Mali 支持）→ **alpha-4（2026-09-26）**，共 4 个 APK 变体：`blender-{lite,full}.apk` 与 `blender-{lite,full}-turnip.apk`。
- 相关 fork：[Wanderson-Magalhaes/blender_for_android](https://github.com/Wanderson-Magalhaes/blender_for_android)（50★，基于 simfeo alpha-1 的派生，针对 Galaxy S24 Ultra / Adreno 750 调优，构建文档 [ANDROID_AI_GUIDE.md](https://github.com/Wanderson-Magalhaes/blender_for_android/blob/main/ANDROID_AI_GUIDE.md)，作者明确声明"不再维护"）。

### 2.3 TUR Termux 包（真正意义上的「Blender CLI in Termux」）

- 打包脚本：[tur-on-device/blender5/build.sh](https://github.com/termux-user-repository/tur/blob/master/tur-on-device/blender5/build.sh)（**5.2.2**）、[blender4/build.sh](https://github.com/termux-user-repository/tur/blob/master/tur-on-device/blender4/build.sh)（**4.5.14**）。注意 `TERMUX_PKG_EXCLUDED_ARCHES="arm, i686"` 且 **仅支持在设备上编译**（`termux_step_get_source` 里 "This package doesn't support cross-compiling."）；依赖含 `libepoxy、glew、vulkan-loader-generic、shaderc、openxr、ffmpeg、oidn…`，构建用 mold，并依赖 `sse2neon`（把 SSE 内联函数映射到 ARM NEON）。
- Blender 源码拉自 projects.blender.org 并做 git-lfs 完整拉取（仿 Arch Linux PKGBUILD）。
- Android/bionic 补丁清单（tur-on-device/blender5 目录，实测存在）：
  - [disable_no-pie.patch](https://github.com/termux-user-repository/tur/blob/master/tur-on-device/blender5/disable_no-pie.patch)（改 `-no-pie`→`-pie`，Android 不允许非 PIE 可执行）
  - [fix-timespec_get.patch](https://github.com/termux-user-repository/tur/blob/master/tur-on-device/blender5/fix-timespec_get.patch)（把 macOS 专用的 `uuid.cc` timespec 分支改为 `__ANDROID__`）
  - [use_posix_ipc.patch](https://github.com/termux-user-repository/tur/blob/master/tur-on-device/blender5/use_posix_ipc.patch)（自实现 `shm_open/shm_unlink`）
  - [sigaction.patch](https://github.com/termux-user-repository/tur/blob/master/tur-on-device/blender5/sigaction.patch)（`BLI_mmap.cc` 的 sigaction 初始化写法在 bionic 下编译失败的回退）
  - [prepend-prefix-share-fonts.patch](https://github.com/termux-user-repository/tur/blob/master/tur-on-device/blender5/prepend-prefix-share-fonts.patch)（`/usr/share/fonts`→`@TERMUX_PREFIX@/share/fonts`；对应 issue [#2392](https://github.com/termux-user-repository/tur/issues/2392) 的"CLI 渲染找不到字体"）
  - [prepend-prefix-to-tmp.patch](https://github.com/termux-user-repository/tur/blob/master/tur-on-device/blender5/prepend-prefix-to-tmp.patch)、[oiio-3.1.patch](https://github.com/termux-user-repository/tur/blob/master/tur-on-device/blender5/oiio-3.1.patch)、[no-error-float_conversion-double_promotion.patch](https://github.com/termux-user-repository/tur/blob/master/tur-on-device/blender5/no-error-float_conversion-double_promotion.patch)
  - blender4 另有 ffmpeg 8.0 与 python-3.14 系列补丁（同目录）。
- 历史沿革：TUR 的 `blender` 包曾长期停在 3.4.1（issue [#1740](https://github.com/termux-user-repository/tur/issues/1740) 提出升级，2025-10-22 合入 blender4 4.4.3→4.5.x，提交 9262c3a）；2026-03 曾 addpkg `blender 1:3.6.23-9`（[#2362](https://github.com/termux-user-repository/tur/issues/2362)）；**2026-10-14 实测 `tur-on-device` 目录现仅剩 blender4 与 blender5**。安装：`pkg install tur-repo && pkg install blender4 / blender5`，命令名为 `blender-4.5`、`blender-5.2` 等（见 [#2685](https://github.com/termux-user-repository/tur/issues/2685) 里的实际调用）。

### 2.4 dshawshank / epai 老端口（Blender 3.6–4.0 时代，GLES）

- 四仓库结构：`lib-android_arm64`（第三方库）、`Utilities-android_arm64`（宿主工具）、[Blender-android_arm64](https://github.com/dshawshank/Blender-android_arm64)（Blender 源码 fork，分支 `blender-v3.6-release`，含 `intern/ghost/intern/GHOST_SystemAndroid.{cc,hh}`、`GHOST_WindowAndroid`、`intern/ghost/intern/android_native_app_glue.h`、`extern/glew-es`、`extern/sdlew`）、[APP-android_arm64](https://github.com/dshawshank/APP-android_arm64)（Android Studio 工程 `com.epai.oblender`）。
- 编译流程文档：[Doc/Compile Flow_en.txt](https://github.com/dshawshank/APP-android_arm64/blob/main/Doc/Compile%20Flow_en.txt)（Android Studio 4.1.1 / NDK 21 / API 30，三次编译 makesdna/makesrna 的鸡生蛋流程）。
- APK：`blender.on.Android.v0.0.3~v0.0.5`（[Releases](https://github.com/dshawshank/APP-android_arm64/releases)，v0.0.5 于 2025-08-07，592MB）。
- 该项目作者对应的社区讨论帖为 devtalk 的 [Issues porting Blender to Android tablets](https://devtalk.blender.org/t/issues-porting-blender-to-android-tablets/35419)（2024-07-03 由用户 **epai** 开帖："I recently ported blender 4.0.0 to a Samsung Android tablet"；与 App 包名 com.epai.* 一致，是否同一人官方未声明——**未证实**）。

### 2.5 gamextra4u/Blender-on-Termux（Wine 路线）

- 仓库只有两个文件：LICENSE 与 [blender](https://github.com/gamextra4u/Blender-on-Termux/blob/main/blender) 脚本，原文核心：
  ```bash
  XDG_RUNTIME_DIR=${TMPDIR} termux-x11 :0&
  am start -n com.termux.x11/com.termux.x11.MainActivity
  wine explorer /desktop=shell,1280x720 C:\\Program Files\\blender-arm64\\blender-launcher.exe
  ```
  即：Termux 里启 termux-x11，用 TUR 的 arm64 **Hangover Wine** 跑 Windows arm64 版 Blender。Blender 官方自 4.3 起提供 Windows arm64 构建（见 [Blender 手册](https://docs.blender.org/manual/en/latest/getting_started/installing/windows.html) 与 [mirror 列表](https://mirror.blender.org/release/Blender5.1/blender-5.1.0-windows-arm64.msi?mirrorlist)），所以该路线技术上成立。**GPU 具体路径（Wine 的 d3d/vulkan 翻译链）未核实**，且项目 2024-12 后未更新。

### 2.6 lfdevs/blender-linux-arm64（供 chroot/proot 用）

- [仓库](https://github.com/lfdevs/blender-linux-arm64)（15★）用 GitHub Actions 构建 **Linux arm64** Blender（release/lite/debug，GCC 11/14，Tags 即补丁版本），产物可下载后在 Android 的 proot/chroot 里直接跑。它不理解 Android GPU，GPU 加速需靠 proot 侧另行接 Turnip（见 3.5）。

---

## 3. GPU 驱动方案（重点）

### 3.1 simfeo 的 APK 端口：Vulkan vendor 驱动 + Turnip via libadrenotools

**A. 默认（vendor 驱动）**
- 只支持 Vulkan，无 OpenGL 回退；`platform_android.cmake` 里 `set(WITH_VULKAN_BACKEND ON)` / `set(WITH_GHOST_ANDROID ON)` / `-DVK_USE_PLATFORM_ANDROID_KHR`，Vulkan 头文件要求比 NDK 自带更新（要用 `VK_KHR_dynamic_rendering_local_read`，Vulkan-Headers 1.4.341）。来源：[platform_android.cmake](https://github.com/simfeo/blender/blob/android/build_files/cmake/platform/platform_android.cmake) 与 BUILDING.md。
- Vulkan 1.1 老驱动走 render-pass fallback；alpha-1 发布说明明确曾"故意不打包 Mesa Turnip"（[alpha-1 release](https://github.com/simfeo/blender/releases/tag/android-alpha-1)）。

**B. Turnip 变体（alpha-4 新增，2026-09-26）**
- 构建脚本 [build_turnip.sh](https://github.com/simfeo/blender/blob/android/build_files/android/build_turnip.sh) 原文要点：
  - `MESA_TAG="${BLENDER_ANDROID_MESA_TAG:-mesa-26.2.3}"`，libadrenotools 固定在 `8fae8ce254dfc1344527e05301e43f37dea2df80`；
  - 克隆 `https://github.com/bylaws/libadrenotools`，用 NDK toolchain 交叉编译；
  - Mesa 交叉编译（关键参数原文）：
    ```
    -Dplatforms=android -Dplatform-sdk-version=$ANDROID_API \
    -Dandroid-stub=true -Dandroid-libbacktrace=disabled \
    -Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl -Dgallium-drivers= \
    -Dopengl=false -Degl=disabled -Dgles1=disabled -Dgles2=disabled \
    -Dglx=disabled -Dgbm=disabled -Dllvm=disabled ...
    ```
    产物 `libvulkan_freedreno.so` → 打包为 `libvulkan_turnip.so`。
  - 可用自备驱动替代：`BLENDER_ANDROID_ADRENOTOOLS=/path/libadrenotools`、`BLENDER_ANDROID_TURNIP_DRIVER=/path/libvulkan_turnip.so`（可来自如 [whitebelyash/AdrenoToolsDrivers](https://github.com/whitebelyash/AdrenoToolsDrivers)）。
- 运行时装/卸载驱动：[vk_backend.cc](https://github.com/simfeo/blender/blob/android/source/blender/gpu/vulkan/vk_backend.cc) 中 `android_try_load_turnip()`：
  - 用 `dladdr` 找到 app 自己的 `nativeLibraryDir`，钩子库与驱动都随之打包进 APK；
  - 读系统属性 `debug.blender.turnip` 决定是否启用（APK 里带了驱动才默认开）；
  - `setenv("TU_DEBUG", tu_debug, 1)`，默认值 **`sysmem`（关闭 tiling）**，可用 `debug.blender.tu_debug` 覆盖；
  - 经 `adrenotools_open_libvulkan(RTLD_NOW, ADRENOTOOLS_DRIVER_CUSTOM, ...)` 加载。
- **无需 root 的关键技巧**：Turnip（HAL 构建）链接了 app 命名空间白名单之外的私有库 `libcutils`/`libhardware`，直接从 APK dlopen 会失败；项目用 [turnip_shim/shim.c](https://github.com/simfeo/blender/blob/android/build_files/android/turnip_shim/shim.c) 自编两个同名垫片 so（提供 `atrace_get_enabled_tags/atrace_*、property_get、hw_get_module`，共 6 个符号），由 [package.sh](https://github.com/simfeo/blender/blob/android/build_files/android/apk/package.sh) 打包，从而在非 debuggable 的正式 APK 里也能加载自带驱动。adrenotools 本身还带 `linkernsbypass`（`android_create_namespace`），用于绕开 linker namespace 限制——全程用户态，**不需要 root**。
- 调试/开关属性（BUILDING.md 表格）：`debug.blender.turnip`（改用 Turnip，打包了驱动时默认 on）、`debug.blender.tu_debug`（Turnip 调试标志，默认 `sysmem`）、`debug.blender.log`（逐帧跟踪）、`debug.blender.lowmem`、`debug.blender.renderdiv`；`build.py --enable-turnip` 实际执行 `adb shell setprop debug.blender.turnip 1`。
- **渲染分工**：Cycles 在 full 包里是 **CPU**（Embree + OIDN 去噪；发布说明称 1080p 去噪约 30 秒/张）；EEVEE、Workbench、UI 走 Vulkan。alpha-4 说明与 [站点下载页](https://blenderandroid.github.io/)。
- 设备现状（alpha-4 发布说明，[更新页](https://blenderandroid.github.io/updates/2026-09-26-main-android-alpha-4/index.html)，2026-09-26）：Turnip 在 Adreno 642L 上"能加载并正确渲染、通过颜色拾取压力测试，但切换视口着色模式时会崩在驱动内部（命令录制路径的空引用）"；**Adreno 830 上 Turnip 首次提交队列即失败**（KGSL 后端 `submit failed: Invalid argument` → device lost），官方建议 830 用 vendor APK；BUILDING.md 另记（2026-08）：Adreno 642L vendor 驱动是默认路径且通过两套测试。

### 3.2 Wanderson fork：Qualcomm 专属绕过

- 针对 Adreno 750（S24 Ultra）。[ANDROID_AI_GUIDE.md](https://github.com/Wanderson-Magalhaes/blender_for_android/blob/main/ANDROID_AI_GUIDE.md) 里的 GPU 修改点包括：
  - "Qualcomm is asked for SPIR-V 1.3 whatever version it reports supporting. Its compiler refuses compute modules emitted as 1.5, which are the ones EEVEE uses for shadows and light culling"（改 [vk_shader_compiler.cc](https://github.com/Wanderson-Magalhaes/blender_for_android/blob/main/source/blender/gpu/vulkan/vk_shader_compiler.cc)）；
  - 显存统计修正：Adreno 750 上原逻辑把 "11084 MiB + 4095 MiB 报成 VRAM: 14.8 GiB"（把系统内存 heap 和受保护 DRM heap 都算了），改为按 `VmaBudget` 统计（`memory_statistics_get()`）；
  - GPU subdivision 在被驱动拒绝时回退 CPU；
  - "it refuses several compute pipelines that are perfectly valid"（Adreno 750 的已知行为，alpha-3 更新页亦确认）。
- 设备踩坑（Issues，见第 4 节）。

### 3.3 官方 demo APK

- 官方路线即 Blender 的 **Vulkan 后端**（[BCON26 演讲](https://conference.blender.org/2026/presentations/4291/)；媒体称"Android 后端依赖 Vulkan，这是让移植可行的关键"，[Marco's Box](https://www.marcosbox.com/2026/09/27/blender-android-apk-ufficiale-tablet-3d/)）。官方是否内置 Mesa Turnip、最低 Vulkan 版本/API 级别**均未公布（未证实）**。官方在系统性收集各机型 Vulkan 扩展能力数据（Jeroen Bakker 的 devtalk 征集）。

### 3.4 Termux 原生：Zink + Turnip（免 root 通用做法）

来自 TUR issue [#1740](https://github.com/termux-user-repository/tur/issues/1740)（robertkirkman，2025-05-21，Samsung Galaxy S9 / Adreno 630 实证）——原文命令：

```bash
pkg upgrade
pkg install x11-repo
pkg install tur-repo
pkg install xfce termux-x11-nightly mesa-vulkan-icd-freedreno mesa-demos
export DISPLAY=:0 TERMUX_X11_XSTARTUP=xfce4-session
LIBGL_ALWAYS_SOFTWARE=1 termux-x11 &      # 注意：只对 termux-x11 这条命令用软件 GL
glxinfo -B | grep -e 'OpenGL version string' -e 'OpenGL renderer string'
# 期望：
#   OpenGL renderer string: zink Vulkan 1.3(Turnip Adreno (TM) 630 (MESA_TURNIP))
#   OpenGL version string: 4.6 (Compatibility Profile) Mesa 25.1.1
blender-4.4
```

- 结论句原文："an Adreno GPU device that can be set into a Zink + Turnip mode providing at least OpenGL 4.3 is probably required to run Blender 4"；Mali "much less likely to be possible"。
- 另一个可选后端（Blender 自带 Vulkan）：`blender-5.2 --gpu-backend vulkan`（[#2685](https://github.com/termux-user-repository/tur/issues/2685)）。
- 组件原理：`mesa-vulkan-icd-freedreno` = Mesa 的 Turnip ICD（装上后在 Termux 的 Vulkan loader 里可见，可用 `vulkaninfo | grep -i devicename` 验证为 `Turnip Adreno (TM) 750` 之类；第三方镜像站可见 26.2.3 的 .deb：[mirrors.utermux.dev 列表](https://mirrors.utermux.dev/termux/apt/termux-main/pool/main/m/mesa-vulkan-icd-freedreno/)）；`mesa-zink`（TUR 包，[build.sh](https://github.com/termux-user-repository/tur/blob/master/tur/mesa-zink/build.sh)，v22.0.5 rev5，meson 参数含 `-Dgallium-drivers=swrast,zink,virgl -Dvulkan-drivers=swrast,freedreno -Dfreedreno-kgsl=true -Ddri3=enabled -Dglvnd=true`）提供 OpenGL→Zink(→Vulkan) 的 libEGL/libGLES；用环境变量切换：`MESA_LOADER_DRIVER_OVERRIDE=zink`、`GALLIUM_DRIVER=zink|virpipe`、`VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json`（示例见 [LinuxDroidMaster 硬件加速指南](https://github.com/LinuxDroidMaster/Termux-Desktops/blob/main/Documentation/HardwareAcceleration.md)）。
- 该指南还给出 glmark2 实测（Lenovo Legion Y700，Adreno 650）：**Turnip 198 分 vs llvmpipe ~90 分**（zink 直接跑在 Termux 下 121 分）——Turnip 是唯一真正显著加速的组合。

### 3.5 proot/chroot：Turnip 以 .deb/.zip 形式注入

- [LinuxDroidMaster 指南](https://github.com/LinuxDroidMaster/Termux-Desktops/blob/main/Documentation/HardwareAcceleration.md)：proot(Debian) 内 `sudo dpkg -i mesa-vulkan-kgsl_24.1.0-devel-20240120_arm64.deb`（第三方 Google Drive 托管，**未证实长期有效**）；Arch chroot 内 `wget https://github.com/MatrixhKa/mesa-turnip/releases/download/24.1.0/mesa-turnip-kgsl-24.1.0-devel.zip`，解压后 `libvulkan_freedreno.so → /usr/lib/`、`freedreno_icd.aarch64.json → /usr/share/vulkan/icd.d/`；运行时 `MESA_LOADER_DRIVER_OVERRIDE=zink TU_DEBUG=noconform PROGRAM`。另有 virgl 路线（Termux 侧 `virgl_test_server_android &`，проot 侧 `GALLIUM_DRIVER=virpipe`）。
- 相关社区源头：r/termux 的 proot DRI3 补丁帖 [reddit.com/r/termux/comments/19dpqas](https://www.reddit.com/r/termux/comments/19dpqas/proot_linux_only_dri3_patch_mesa_turnip_driver/)。B 站也有"LXC 容器全局 GPU 加速跑 Blender"（Redmi K40 Pro / Adreno 660，Turnip+Zink）的视频案例（BV17iumziEeS，**未逐帧核实**）。
- 注意：普通 `chroot` 需 root；**proot-distro 免 root**。

### 3.6 dshawshank 老端口：GLES/EGL（厂商系统 GL）

- 其 Blender fork 实现 [GHOST_ContextEGL.cc](https://github.com/dshawshank/Blender-android_arm64/blob/blender-v3.6-release/intern/ghost/intern/GHOST_ContextEGL.cc) 中保留了 `EGL_OPENGL_ES_API` / `s_gles_sharedContext` 等 GLES 分支，配合 `extern/glew-es`（GLES 版 glew）和 `extern/sdlew`（SDL for Android）；APP 端用 SDLActivity + `WindowGLSurfaceView`（GLSurfaceView → Android 系统 `libEGL/libGLESv2`，即厂商 GLES 驱动）。**未见任何 Turnip/自定义驱动注入（未证实有）**；GPU 就是系统 GLES。
- 生态评价（devtalk 帖内）：epai 反馈 GLES 3.1 限制——"OpenGL 3.1 ES uses medium float precision, does not have sampler1D, sampler1DArray"，材质预览/渲染模式下贴图全黑；Sergey（Blender 核心开发者）回复 "The missing texture might be just a missing feature in OpenGL ES"，并指出 Vulkan 后端（4.3 beta）才是移动端的现实路径（[devtalk 35419](https://devtalk.blender.org/t/issues-porting-blender-to-android-tablets/35419)；[DIGITAL PRODUCTION 报道](https://digitalproduction.com/2025/07/14/blender-on-android-ported-not-polished-yet/)）。

### 3.7 root 问题小结

| 路线 | 是否需要 root | 免 root 靠什么 |
|---|---|---|
| APK + Turnip（simfeo） | 否 | 只 dlopen 自己 APK 的 nativeLibraryDir；私有库 libcutils/libhardware 用自编垫片；adrenotools+linkernsbypass 建命名空间 |
| Termux zink+Turnip | 否 | 全部安装于 `$PREFIX`（用户目录），Vulkan loader 找 ICD.json |
| proot | 否 | proot 用户态模拟 |
| chroot | 是（或用 proot 代替） | busybox chroot 需 root |
| 旧 APK（dshawshank） | 否 | 系统 GLES |

---

## 4. 踩坑记录（设备 / 症状 / 来源，按项目）

**simfeo 端口（alpha-4 发布说明/更新页，2026-09-26）** [更新页](https://blenderandroid.github.io/updates/2026-09-26-main-android-alpha-4/index.html)：
- Adreno 642L + Turnip：用 EEVEE 后 **GPU 丢失**（known issue）；
- Adreno 710（Moto g Stylus 5G 2024）：alpha-4 能启动了，但**视口/UI 出现重复几何与噪点**；
- Adreno 830：swapchain 超过 5 张图时崩溃/黑屏（已修）；**Turnip 在 830 上 KGSL 首提即 `submit failed: Invalid argument` → device lost**（BUILDING.md，2026-09）→ 建议用 vendor APK；
- Adreno 通用：qcom **vertex-input bug** 的 workaround 此前只在 Windows 生效，Android 上会导致"图元在屏幕上重复绘制"，alpha-4 起生效；
- Mali-G57 r32：UI/网格出现杂散三角形（相对 alpha-3 的回归，原因未知）；
- 修 EEVEE 类问题的三个 GPU 特性：Mali 缺 "dual source blending / vertex stage stores / clip distance"（alpha-3 说明，[更新页](https://blenderandroid.github.io/updates/2026-09-07-main-android-alpha-3/index.html)）；
- 其他上限：纹理默认 cap 1024（否则一批 4K 贴图会被系统静默杀掉，因为 **GPU 分配不计入进程 RSS**）；<6GB RAM 设备缩小 shadow pool；反射探针 workgroup 32→16（部分 Adreno 即便报告支持 32 也必须降）。

**simfeo 变体（Wanderson fork）Issues** [issues](https://github.com/Wanderson-Magalhaes/blender_for_android/issues)：
- #3 Sony Xperia 5 IV（SD 8 Gen 1 / Adreno 730，Android 14）：启动即 ANR 日志 "Buffer processing hung up due to stuck fence. Indicates GPU hang"（2026-09-17）；
- #5 OnePlus Pad 2（8 Gen 3，Android 16）：黑屏后退出，无报错（2026-09-27）；
- #7 Mali-G57 MC2 + Blender 5.3 Lite：切 Material Preview / Rendered 立即崩溃（Solid/Wireframe 正常）（2026-10-02）。

**TUR Termux（75 条 blender 相关 issue，关键几条）** [搜索页](https://github.com/termux-user-repository/tur/issues?q=blender)：
- [#2685](https://github.com/termux-user-repository/tur/issues/2685)（2026-07-25）blender5→5.1 后 `--gpu-backend vulkan` 段错误；后续 blender-5.2 修复（回报者确认）；同帖中报告者 OpenGL 后端报 `zink_context.c: assertion "!ctx->blitting" failed`；维护者 robertkirkman 自称"我所有设备上 Vulkan 后端都崩"，另一用户 813ethan 用 **Adreno 829 + Turnip 跑通 Vulkan**；
- [#2694](https://github.com/termux-user-repository/tur/issues/2694)（2026-07-28）点选/拖拽时崩在 `spvtools::opt::AggressiveDCEPass`（libglslang）；glslang 16.4 复现、16.3.0 对部分设备可解；与 Vulkan 后端和软件 ICD 混用有关；
- [#2363](https://github.com/termux-user-repository/tur/issues/2363)（2026-03-21）5.1 包 "Pointer tag truncated aborted"（一次坏版本，后修复）；
- [#1740](https://github.com/termux-user-repository/tur/issues/1740)（2025-08-19）另一用户（Adreno 640）：只能 llvmpipe 跑；强行 Zink/Turnip 时报 "not enough SSBO binding locations" 或要求 OpenGL 4.3；
- [#2392](https://github.com/termux-user-repository/tur/issues/2392)（2026-03-31）**CLI 渲染可用**，但相对路径字体找不到（GUI 正常），临时方案改绝对路径；
- [#2376](https://github.com/termux-user-repository/tur/issues/2376)（open）音频播放卡顿（非 GPU）；
- [#513](https://github.com/termux-user-repository/tur/issues/513)（2023）老 `virglrenderer-android` + GALLIUM_DRIVER=virpipe 下 Blender 段错误（历史记录）。
- 社区硬件备注：Termux 的 Turnip/Freedreno 对 **Snapdragon 8 Elite（Adreno 830）不支持**（XDA 讨论 [4748245](https://xdaforums.com/t/termux-hardware-acceleration-for-snapdragon-8-elite.4748245/)）；一般兼容 6xx/7xx，"例外如 710、642L"（LinuxDroidMaster 指南与 #1740）。

**老端口（dshawshank/epai，2024）**：材质预览/渲染模式贴图黑、样条曲线多线/点、GLES precision/sampler1D 问题、输入事件处理 bug（见 devtalk 35419 前 100 帖）。

---

## 5. 渲染后端现状核对

- **Cycles / OpenCL / Adreno**：Cycles 的 OpenCL 支持已在 **Blender 3.0 的 Cycles X 重构中移除**（官方 3.0 release notes：[开发者文档](https://projects.blender.org/blender/blender-developer-docs/raw/branch/main/docs/release_notes/3.0/cycles.md)；[Phoronix](https://www.phoronix.com/news/Blender-3.0-Lands-Cycles-X)）。4.x/5.x 的 Cycles GPU 后端只有 CUDA/OptiX/HIP/oneAPI/Metal（[Cycles GPU Rendering 手册](https://docs.blender.org/manual/en/latest/render/cycles/gpu_rendering.html)），**没有任何 Android 可用的 GPU Compute 路径**。所以"Adreno 上用 Cycles OpenCL 渲染"这个组合在现版 Blender 里不存在；**未发现任何人在 Android 上用 OpenCL 跑 Cycles 的公开记录**。所有 Android 路线的 Cycles = CPU（simfeo full APK 用 Embree+OIDN；TUR 包同理）。
- **EEVEE**：
  - Vulkan 路线（APK）：simfeo alpha 4 在 Adreno 642L（vendor 与 Turnip 都试过，Turnip 有 GPU 丢失问题）、Xclipse 920、Mali-G57 上均跑起来；Wanderson 分支在 Adreno 750 上跑通（做了 compute pipeline 拒绝的 workaround）；
  - GL 路线（Termux）：robertkirkman 的 **Adreno 630 + Zink + Turnip（OpenGL 4.6）跑 Blender 4.4 GUI/EEVEE 有实证**（#1740 + [视频](https://www.youtube.com/watch?v=ikP6u7PpnZQ)）；Loaded4Bears 用同一套指南也成功（#1740 评论）；反例：Adreno 640 只能 llvmpipe、zink 报 SSBO 绑定位置不足。
  - dshawshank 时期（GLES）：OpenGL ES 特性缺失导致 EEVEE 材质预览不完整，属于"不可行"的历史证据。
- 历史注记：Blender 曾有一个 2012 GSoC Android 分支 `soc-2012-swiss_cheese`（Sergey 在 devtalk 帖中提到）。

---

## 6. 对「免 root 通用高通 GPU 驱动组件」的启示（可复用清单）

1. **驱动注入层选 libadrenotools**：被 simfeo 端口直接采用（[build_turnip.sh](https://github.com/simfeo/blender/blob/android/build_files/android/build_turnip.sh) 固定 rev `8fae8ce`），它解决的是"无 root 替换 Vulkan 驱动"：从 app 自己的 nativeLibraryDir 加载任意 `libvulkan_*.so`，支持 hook 库与 linker namespace 绕过（linkernsbypass）。
2. **私有平台库垫片（关键坑）**：Turnip 的 Android HAL 构建依赖白名单外的 `libcutils`/`libhardware`（仅 6 个符号：atrace_*、property_get、hw_get_module），打包同名 shim so 即可在正式（非 debuggable）APK 中 dlopen 成功——[shim.c 全文](https://github.com/simfeo/blender/blob/android/build_files/android/turnip_shim/shim.c)。
3. **Turnip 的最小正确构建参数**（可直接抄）：`-Dplatforms=android -Dplatform-sdk-version=<api> -Dandroid-stub=true -Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl -Dgallium-drivers= -Dopengl=false -Degl=disabled ...`（纯 Vulkan ICD，不要 GL，减小体积和依赖面）。
4. **预编译 Turnip 分发源**：[whitebelyash/AdrenoToolsDrivers](https://github.com/whitebelyash/AdrenoToolsDrivers)（468★，偏 A8XX）、[MatrixhKa/mesa-turnip](https://github.com/MatrixhKa/mesa-turnip)（proot 用 deb/zip 形式）、以及上游 Mesa 自建；simfeo 也支持 `BLENDER_ANDROID_TURNIP_DRIVER` 指向任意文件。
5. **Termux 侧"现成组件"**：`mesa-vulkan-icd-freedreno`（Turnip ICD）+ `mesa-zink`/TUR（OpenGL→Zink），切换靠 `MESA_LOADER_DRIVER_OVERRIDE=zink`、`VK_ICD_FILENAMES`、`TU_DEBUG`——**不需要 root，也不需要改系统分区**，这是目前最"通用"的高通 GPU 加速组件组合（glmark2 Turnip 198 vs llvmpipe 90，实测）。
6. **按设备绕坑的必备开关**：
   - `TU_DEBUG=sysmem` 关闭 tiling（a7xx 上 tiling 会 fault，A810/A830 的 GMEM 被 Mesa 标为 broken）——simfeo 默认全局启用；
   - 针对 Qualcomm 的 SPIR-V 1.3 强制（其编译器拒绝 1.5 的 compute 模块）——Wanderson 分支；
   - Vulkan 1.1 设备准备 render-pass fallback；
   - 属性开关（`debug.blender.*`）比重新打包更灵活，但注意现代 Android 上应用自身设置自定义属性受限，实际是 adb/开发者流程。
7. **系统集成注意**：GPU 分配不体现在 RSS → 需主动限纹理/阴影内存，否则被系统静默杀死（simfeo 的经验），这对任何"长驻 GPU 应用"都适用。
8. **不要指望的路径**：Cycles+OpenCL（OpenCL 已被移除）、Mali 走 Turnip（Turnip 仅 Adreno）、Adreno 830/SD 8 Elite 走 Termux Turnip（XDA 实测不支持；simfeo 的 Turnip 在 830 上也 KGSL 报错）。

---

## 7. 未证实 / 边界说明

- 「Blender CLI on Android」作为独立项目：**不存在**（本报告已覆盖所有能找到的相关项目）；CLI 能力实际由 TUR 包（`blender-5.x -b ...`）与 proot/chroot（`blender -b file.blend -o ... -E ENGINE -s N -e M -a`，见 [LambDa 指南](https://github.com/luckiday/LambDa/blob/master/doc/instruction.md)）提供。**无 X 环境纯 headless 的 EEVEE 渲染案例未见公开记录（未证实）**；Cycles CPU 的 CLI 渲染有间接证据（TUR #2392）。
- 官方 demo APK 的具体 GPU 栈（是否含 Turnip）、最低 Android/Vulkan 要求：官方未公布（**未证实**，媒体转述称需 Vulkan）。
- 官方 android 分支的 GHOST/APK 代码是否将在 2027 前合并进公开仓库：未知；当前公开镜像确认**没有** `GHOST_SystemAndroid.cc`/`build_files/android`（2026-10-14 实测 404）。
- dshawshank 与 devtalk 用户 epai 是否同一人：强暗示（App 包名 com.epai.oblender），无官方声明（**未证实**）。
- 0★ 系列仓库（werdio325-png/blender-android、46Neon/blender-app、system32ovo/BlenderForAndroid 等）未逐一下载核实，可能是复刻/AI 生成/占位仓库（**未证实**）。
- Gumroad 页面（"Blender 5.3 Alpha for Android"）为第三方搬运/测试发布，与 simfeo 的关系未核实（**未证实**）。
- 本报告中所有"设备可跑"结论均来自相应 issue/发布说明作者自述，本机无 Android 设备实测。

---

## 补记（2026-10-15，用户澄清）

用户指出：他说的「blender cli android」是自己的项目
**[greyoak111/blender-cli-android](https://github.com/greyoak111/blender-cli-android)**。
本报告开头「不存在单一 CLI 项目」的结论据此修正（检索未覆盖到该仓库）。

与本次调研的交叉印证（同款 Lenovo TB320FC / Adreno 730 实测）：

- 链路完全同构：`Blender → EGL(Mesa surfaceless) → Zink → Vulkan loader → Turnip
  → /dev/kgsl-3d0`；同样确认 `/dev/dri` 不可用、只能走 KGSL
- 执行环境不同：它走 **glibc/Debian 侧**（glibc 运行时 + Debian trixie blender 4.3.2
  依赖闭包 + lfdevs/mesa-for-android-container 补丁版 Mesa）；本组件走
  **bionic/Termux 原生侧**（$PREFIX Mesa + Termux freedreno ICD）
- 它独有的坑（glibc 侧）：libglvnd 的 `__EGL_VENDOR_LIBRARY_FILENAMES` —— 缺了只报
  误导性的 `EGL_BAD_PARAMETER`（其 pitfalls #13）
- 它实测 EEVEE GPU 比 llvmpipe 快 5–19 倍（同场景 A/B 对照），是「zink+Turnip 能扛
  真实渲染负载」的强证据
- 其坑清单与本组件互补：`#19 LD_LIBRARY_PATH 毒化`、`#15 着色器缓存要固定位置`
  （本组件 gpu-run 已采纳 `MESA_SHADER_CACHE_DIR`）、`#22 /dev/dri 存在≠可用`
- 环境变量差异（本机实测）：其补丁版 Mesa 认 `MESA_LOADER_DRIVER_OVERRIDE=zink`；
  Termux Mesa 只认 `GALLIUM_DRIVER=zink`（前者单设会静默退回 llvmpipe）——
  本组件 gpu-run 现已双设，兼容两种构建
