# 免 root 通用高通 GPU 驱动组件 — 研究报告（阶段一）

日期：2026-10-15 · 测试机：Lenovo TB320FC（Legion Y700 2023）
芯片：骁龙 8+ Gen 1（SM8475, taro）· GPU：Adreno 730 · Android 15 (SDK 35)

## 结论摘要

**五条 GPU 路径全部在本机 app uid（无 root）下验证通过**：

| 路径 | 机制 | 实测结果 |
|---|---|---|
| Vulkan（厂商驱动） | 系统 `/system/lib64/libvulkan.so`，默认 | Adreno (TM) 730 · Vulkan 1.1.128 ✅ |
| **Vulkan（Turnip，通道 A：标准 ICD）** | Termux `mesa-vulkan-icd-freedreno` 26.2.5 + patchelf rpath + `VK_DRIVER_FILES` + `$PREFIX` loader | Turnip · Vulkan **1.4.354** ✅ |
| Vulkan（Turnip，通道 B：HAL） | GraphicsEnv 设驱动目录 + 系统 loader 加载 `vulkan.adreno.so`（HMI） | Turnip · Vulkan **1.4.335** ✅ |
| OpenGL ES（厂商） | 系统 `/system/lib64/libEGL.so` + `libGLESv2.so` | Adreno (TM) 730 · GLES 3.2 ✅ |
| **OpenGL（zink on Turnip，两条通道皆可）** | `GALLIUM_DRIVER=zink`；通道 A 只需 +`VK_DRIVER_FILES`，通道 B 需 AOSP loader shim + bootstrap | `zink Vulkan 1.4(Turnip Adreno (TM) 725)` ✅ |
| OpenCL（厂商） | `$PREFIX/lib/libOpenCL.so` ← 拷贝 `/vendor/lib64/libOpenCL.so` | OpenCL 3.0 · 向量加 kernel PASS ✅ |

## 核心机制（为什么可行）

### 1. 那堵墙：linker namespace

app 进程直接 `dlopen("/vendor/lib64/libOpenCL.so")` 或 `/vendor/lib64/hw/vulkan.adreno.so`
会被拦：

```
dlopen failed: library ".../libOpenCL.so" needed or dlopened by "..." is not
accessible for the namespace "(default)"
```

两条免 root 的正路（都不碰系统分区、进程级生效）：

**通道 A（标准 ICD，最顺）**：任何放在 app 私有目录的 .so 都能被
`$PREFIX` 的 Khronos Vulkan loader 通过 `VK_DRIVER_FILES` 加载（namespace 只拦
`/vendor`，不拦 app 目录）——前提是该 .so 是**标准 ICD**（导出
`vk_icdGetInstancePlatformIDs` 家族），且它自己的依赖能被解析（app 目录里的 so 没有
rpath，用 `patchelf --set-rpath $PREFIX/lib` 修一下即可，实测这是 Termux Turnip 加载
失败的全部原因：`libandroid-shmem.so` 找不到）。

**通道 B（HAL 驱动，厂商 OTA 同款）**：Android 的「可更新 GPU 驱动」机制（`GraphicsEnv`）：

- `libgraphicsenv.so`（**app 可直接 dlopen**）导出 `getInstance()` 和
  `setDriverPathAndSphalLibraries(path, sphal_libs)`
- 设置后，系统 Vulkan loader 的 `getDriverNamespace()` 为目录建 ISOLATED namespace
  （自动链入 LLNDK/VNDK-sp，Turnip 的依赖恰好只有这些），从目录 dlopen
  **`vulkan.<ro.hardware.vulkan>.so`**（本机 → `vulkan.adreno.so`）
- loader 要求：`dlsym("HMI")` 得 `hw_module_t`，`hmi->id=="vulkan"`，
  `module->common.methods->open(..., "vk0", &device)`。AdrenoToolsDrivers 的 Turnip
  构建即为这种 **HAL 风格**（只导出 `HMI` 一个符号，248 字节，与厂商 HAL 相同）

### 2. 两种 Turnip 来源

| | 通道 A | 通道 B |
|---|---|---|
| 来源 | Termux 官方 `mesa-vulkan-icd-freedreno`（`packages-cf.termux.dev`，26.2.5） | AdrenoToolsDrivers（`v26.0.0-rc08` → `Turnip_v26.0.0_R8.zip`） |
| 形态 | 标准 ICD（`libvulkan_freedreno.so` + `freedreno_icd.json`） | HAL 驱动（`vulkan.ad07xx.so`，HMI） |
| 装载 | `$PREFIX` Khronos loader + `VK_DRIVER_FILES` | 系统 loader + GraphicsEnv |
| 用于 | `-lvulkan` 的 CLI 程序、zink（零垫片） | 链系统 libvulkan 的程序 |
| 修复 | `patchelf --set-rpath $PREFIX/lib` | 改名 `vulkan.adreno.so` + `--set-soname` |

### 3. zink（GL on Vulkan）的注意点

- 必须 `GALLIUM_DRIVER=zink` 强制（`MESA_LOADER_DRIVER_OVERRIDE=zink` 在这套 Mesa 里
  会静默退回 llvmpipe）
- 环境：`EGL_PLATFORM=surfaceless`（CLI 无显示服务器）
- 通道 A：`VK_DRIVER_FILES` 指 ICD json 即可（zink→prefix loader→ICD）
- 通道 B：zink 的 RUNPATH 抓 prefix loader（不认 HMI），需把 `/system/lib64/libvulkan.so`
  拷成 `<shim>/libvulkan.so.1` 并 `LD_LIBRARY_PATH` 抢先
- 实测：`GL_RENDERER: zink Vulkan 1.4(Turnip Adreno (TM) 725 (MESA_TURNIP))`

### 4. OpenCL：ocl-icd 为什么不行

`$PREFIX` 里已有 ocl-icd（Khronos loader），但它要求 ICD 实现
`clIcdGetPlatformIDsKHR` 扩展，**高通的 ICD 没实现**（Android 上走 manifest 白名单机制）：

```
_get_function_addr: Missing function 'clIcdGetPlatformIDsKHR' in ICD, should be skipped
→ clGetPlatformIDs 返回 -1001
```

**解法**：高通的 `libOpenCL.so` 本身就是完整运行时，且 soname 恰好也是 `libOpenCL.so` ——
把 `$PREFIX/lib/libOpenCL.so` 换成它的拷贝即可，任何链 `-lOpenCL` 的程序零改动直接用上 GPU
（ocl-icd 原文件留备份）。依赖检查：它只依赖 `libcutils/libvndksupport/libc++/libc/libm/libdl`
（全是系统库，无需 namespace 处理）。

### 5. 其它已验证事实

- `/dev/kgsl-3d0` 世界可读写（`crw-rw-rw-`，label `gpu_device`）——Turnip 的 kgsl 后端可用；
  `/dev/dri/*` 对 app 不可见（**不能走 DRM/msm 后端**，通道 A 的 Termux 构建双后端，运行时走 kgsl）
- 系统 loader 不认 `VK_DRIVER_FILES`（实测无效），只认 GraphicsEnv 驱动目录
- `$PREFIX` 自带 Mesa 26.2.4（swrast/zink/lavapipe/lvp ICD），但没有 turnip/freedreno 的 Vulkan ICD
- `GraphicsEnv::setDriverPathAndSphalLibraries` 同一进程只生效一次（先设者赢）
- 部分 Termux 镜像证书过期 —— **别用 `curl -k` 绕**（拉的是驱动库，关了证书校验等于谁都能塞一个进来），
  证书不对就换下一个镜像（`lib/fetch_turnip.py` 已经这么做）

## 案例对标：Blender on Android（调研结果）

用户本人的 **[greyoak111/blender-cli-android](https://github.com/greyoak111/blender-cli-android)**
是本场景的正面案例（不走 Termux：glibc 运行时 + Debian 依赖闭包 + 补丁版 Mesa，
在同款 TB320FC 上实测 EEVEE 比软渲快 5–19×，链路同样是 surfaceless→zink→Turnip→KGSL）。
除此之外，Android 上跑 Blender 还有这几条路线：

| 路线 | 代表 | GPU 方案 | CLI? |
|---|---|---|---|
| 官方 APK（BCON26 demo） | blender.org/demo/tablet | 纯 Vulkan（官方在收集机型能力数据） | 否 |
| 社区 APK 端口 | simfeo/blender（最完整，alpha-4） | Vulkan；可选 Turnip（libadrenotools + **turnip_shim** 补 libcutils/libhardware 6 个符号 + `TU_DEBUG=sysmem` 默认关 tiling） | 否 |
| **TUR Termux 包** | `tur-on-device/blender5`（5.2.2）、`blender4`（4.5.14） | **zink + Turnip**（`mesa-vulkan-icd-freedreno` + `mesa-zink`）；或 `--gpu-backend vulkan` | **是**（`blender-5.2 -b ...`） |
| proot/chroot / Wine | Linux arm64 构建 / Hangover Wine | Turnip 注入或系统 GLES | 是 |

要点：

- **Cycles 在 Blender 3.0 移除了 OpenCL**，Android 上 Cycles 只有 CPU（Embree+OIDN）；
  「Adreno 上 Cycles OpenCL」在现版不存在。EEVEE/Workbench/UI 才有 GPU 路线（Vulkan）
- Termux 社区 recipe（与本组件最相关）：`mesa-vulkan-icd-freedreno` + zink，
  `GALLIUM_DRIVER=zink` + `VK_ICD_FILENAMES`；glmark2 实测 **Turnip 198 分 vs llvmpipe 90 分**
  （Lenovo Legion Y700, Adreno 650）——本机 Adreno 730 只会更好
- 已知设备坑：a7xx 上 tiling 可能 fault（simfeo 默认 `TU_DEBUG=sysmem`）；
  **Adreno 830/SD 8 Elite 上 Turnip KGSL 首提即失败**（建议 vendor 驱动兜底）；
  Adreno 642L Turnip 有 GPU 丢失、Adreno 710 UI 噪点；GPU 分配不计入进程 RSS（需限纹理内存）
- 完整调研：见 `BLENDER_CASE.md`（子代理产出，含全部链接与逐项目细节）

**对本组件的启示**：通道 A（标准 ICD）正是 Termux 社区 + Blender-on-Termux 走的路，
与我们的 CLI 场景完全同构；组件应优先实现通道 A，通道 B 作为补充。

## 组件设计草案

```
$PREFIX/lib/gpu-driver/
  icd/libvulkan_freedreno.so     # 通道 A：Termux Turnip（patchelf 修好 rpath）
  icd/freedreno_icd.json         # 指向上面
  hal/vulkan.adreno.so           # 通道 B：AdrenoTools HAL 驱动
  hal/gpu_bootstrap.so           # 通道 B 的 LD_PRELOAD 垫片
  hal/loader_shim/libvulkan.so.1 # AOSP loader 拷贝（zink 通道 B 用）
  vendor/libOpenCL.so            # 厂商 OpenCL ICD 拷贝
$PREFIX/bin/gpu-run              # 包装器：gpu-run [-m icd|hal] [-g] <程序>（设好环境变量后 exec）
$PREFIX/bin/gpu-info             # 自检：GPU 型号 / 各栈可用性
$PREFIX/bin/gpu-switch           # opencl on|off（换/还原 libOpenCL.so，带备份）
~/.claude/skills/gpu-driver/SKILL.md
```

- **零系统改动**：所有文件在 app 私有目录；`VK_DRIVER_FILES`/`LD_PRELOAD` 只影响被包装的进程
- **通用性**：按 GPU 代际选 Turnip 变体（a6xx/a7xx/a8xx），流程对其它骁龙一致
- 厂商 Vulkan/GLES 零配置可用，组件只在需要 Turnip / zink / OpenCL 时介入

## 支持矩阵与边界（AdrenoTools 调研汇总，2026-10-14 检索）

**Turnip 代际覆盖**（同一二进制作，运行时按 chip 选择）：

| 代际 | Turnip | Vulkan | 分发 |
|---|---|---|---|
| a5xx（506/509/512…） | **永远不会有**（mesa-dev 2025-11 定论，"reward is not worth it"） | — | 只能厂商 blob |
| a6xx（618/640/650/660…） | ✅ | 1.3 | K11MCH1 "Standard" 桶 / Termux ICD |
| a7xx（710–750，含本机 730） | ✅ | 1.4 | 同上；A710/720 另有实验变体 |
| a8xx（810–840） | 实验（"very beta"） | 1.4 | 独立 a8xx zip；830/8 Elite 有 KGSL 提交失败报告 |

- 其它预编译源：The412Banner/Banners-Turnip（跟 Mesa main）、StevenMXZ、Weab-chan CI；
  Termux 官方 `mesa` + `mesa-vulkan-icd-freedreno`（26.2.5，msm+kgsl 双后端）
- libadrenotools（`bylaws/adrenotools` 已 404，真名 **libadrenotools**，2024-09 起休眠）：
  liblinkernsbypass（伪造 caller 绕 namespace + 改写 soname 加载第二份 libvulkan）
  + android_dlopen_ext hook 重定向驱动加载；**面向 APK**，本组件的两条通道都不依赖它
- 风险提示：Android 16 起 GPU ioctl 白名单过滤（OEM 可选）可能拒新驱动；
  16KB 页设备要求 .so 对齐（两个 Turnip 均 NDK r29 构建，合规）
- 策略依据：AOSP `app.te` 明文 `allow appdomain gpu_device:chr_file rw_file_perms` ——
  app 访问 `/dev/kgsl-3d0` 是 SELinux 允许的
- 完整报告：`ADRENOTOOLS_CASE.md`

## 组件（本仓库）

两种安装形态共用同一份脚本（`bin/` `lib/` `skill/`）：

```
install.sh --dry-run / --fetch / --hal-zip   # 手动/完整版安装器（幂等）
bin/gpu-run [-m icd|hal|vendor] [-z] [--surfaceless] [--opencl] <程序>
bin/gpu-info                                  # 自检（退出码 0 = Turnip 可用）
bin/gpu-switch opencl on|off|status           # OpenCL 换装（带备份，会改 $PREFIX）
lib/probe.py  lib/fetch_turnip.py
src/gpu_bootstrap.cpp                         # 通道 B 垫片源码（现场编译）
recipe/recipe.json                            # cccodroid 组件市场配方
```

- **市场组件**（cccodroid 应用 → 插件市场 → `gpu-driver`）：从 Termux 官方仓库下发
  `mesa-vulkan-icd-freedreno + mesa + vulkan-tools`，脚本落在
  `$PREFIX/share/cccodroid/components/gpu-driver/`，入口 `$PREFIX/bin/gpu-{run,info}`。
- **手动/完整版**：脚本落在 `$PREFIX/lib/gpu-driver/`，多一个可选 HAL 通道和 `gpu-switch`。

实测（TB320FC，Adreno 730）：默认 → Turnip 1.4.354；`-z --surfaceless` → `zink(Turnip)` 且渲染自测 PASS；
`--opencl` → 厂商 OpenCL 3.0 向量加 PASS；`-m hal` → 系统 loader 载 Turnip 1.4.335；
`--vendor` → 厂商 730。`--opencl` 与市场版全程不动 `$PREFIX` 里的文件。

## 免 root GPU 计算（OpenCL/Vulkan compute）现状

第三路调研结论（`OPENCL_CASE.md`，含本机只读实测）：

- **厂商 OpenCL 直连**：把 `/vendor/lib64/libOpenCL.so` 拷进 app 私有目录按绝对路径 dlopen
  即可（本组件 `gpu-switch opencl on` 的做法）；`LD_LIBRARY_PATH=<该目录>` 也行。
  机制钉死到 `/linkerconfig/ld.config.txt`：app shell 子进程走 `[system]` 命名空间组，
  `permitted.paths` 含 `/data` 不含 `/vendor/lib64`；`LD_LIBRARY_PATH` 对非 setuid 进程
  会被 bionic 装进 default namespace 搜索路径。**SELinux 不是障碍**（策略明确允许）。
  备选：`android_dlopen_ext` + `__loader_android_get_exported_namespace("vndk")` + flags `0x200`。
- **ocl-icd 注册 ICD 路线对 Adreno 不通**（Termux `opencl-vendor-driver` 包自己也标 Adreno
  "不支持"）——别恋战，直接换文件（本组件做法）。
- **clvk（OpenCL over Vulkan）**：Termux 有 2026-10 新包；在 **Turnip（Vulkan 1.4）上实测有效**，
  性能≈原生 Vulkan；但 llama.cpp 的 OpenCL 后端因缺 subgroups 拒收。
- **llama.cpp 是本机最合适的 GPU 计算目标**：其 Vulkan 后端硬性要求 Vulkan 1.2，
  而本机厂商驱动只有 **1.1.128 → 必须 Turnip**（本组件 `gpu-run llama-cli ...` 即可满足）；
  社区实测 Adreno 830+Turnip 45.8 t/s vs CPU 37.1 t/s、CPU 占用降 6.6×。
- **Blender**：Cycles 无 GPU 计算后端（3.0 删 OpenCL，无 Vulkan compute 计划）——
  Blender CLI 在 Adreno 上只有 CPU 渲染；GPU 只服务 EEVEE/视口。
- rusticl：上游对 freedreno 已默认启用（Linux），**Android 上无实证**，不作为主路径。

## 待办

- [x] blender cli android 案例调研（`BLENDER_CASE.md`）
- [x] AdrenoTools 机制与支持矩阵（`ADRENOTOOLS_CASE.md`）
- [x] 免 root OpenCL/计算路径总览（`OPENCL_CASE.md`）
- [x] 两条 Turnip 通道本机验证 + 组件沙盒验证 + 渲染自测 PASS
- [x] 市场组件配方（`gpu-driver`）+ 真机安装
- [ ] glibc 侧组件（Debian/Termux-glibc 依赖闭包 + `lgpu-run`）
- [ ] clvk 的 glibc 版
