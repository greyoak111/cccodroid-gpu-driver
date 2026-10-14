> 说明：本文为子代理（Claude Code research agent）调研产物，检索日期 2026-10-14；除网页/GitHub 证据外，包含在目标设备上进行的**本机只读实测**（未安装/未下载/未编译任何东西）。

# 免 root 在骁龙/Adreno 上做 GPU 计算（OpenCL / Vulkan compute）可行路径调研

**日期：2026-10-14**。本报告除网页/GitHub 证据外，还包含在**本机（正是"应用内 shell、app uid、无 root"场景）的只读实测**——本机即一台 Adreno 730 设备上的 app uid shell，实测结果对所有结论都标注了 ✅/未证实。

本机环境（供对照）：`ro.product.model=TB320FC`（联想 Legion 平板）、SM8475（骁龙 8+ Gen 1）、**Adreno 730**、Android 15（SDK 35）、uid=10391、SELinux `untrusted_app_27`。`/vendor/lib64/libOpenCL.so` 存在，且在本机 `/vendor/etc/public.libraries.txt` 白名单内。

## TL;DR 结论表

| # | 路径 | 可行性 | 一句话结论 |
|---|------|--------|-----------|
| 1 | app 进程直接 dlopen vendor `libOpenCL.so` | **高**（Adreno 上本机已实测跑通 OpenCL 3.0） | 绝对路径会被 linker namespace 拒；但**复制到 /data 按绝对路径加载、LD_LIBRARY_PATH、android_dlopen_ext+导出命名空间**三条路都实测可用；JNI 进程内则用 `<uses-native-library>` |
| 2 | clvk（OpenCL over Vulkan） | **中-高**（有 Termux 包、有实测案例；给 llama.cpp 用会踩 subgroups 坑） | 维护活跃（2026-10 仍有提交），Termux 打包了 clvk；在 Turnip 上实测有效，性能≈原生 Vulkan |
| 3 | rusticl（Mesa OpenCL） | **低-中**（上游支持 freedreno，但 Android 现成路径未证实） | 上游对 Adreno/freedreno 已默认启用（Linux 侧）；Android/Termux 有 `mesa-opencl-icd-rusticl` 包但只编了 llvmpipe/zink 后端，"rusticl→zink→Turnip" 无实测案例 |
| 4 | 直接 Vulkan compute | **高**（llama.cpp）；**低**（Blender） | 本机 app-shell 里用系统 loader 已成功枚举 Adreno 730；llama.cpp Vulkan 后端需 **Vulkan 1.2**（本机 vendor 驱动只有 1.1.128 → 需 Turnip）。Blender 的 Cycles 没有 Vulkan/OpenCL compute 后端，GPU 只能用于 EEVEE/视口 |
| 5 | pocl / ACL / "OpenCL-on-ANGLE" | 低 / 不适用 / 不存在 | pocl 是 CPU 实现（Android 有历史支持）；ACL 只支持 Arm GPU；不存在 OpenCL-on-ANGLE，OpenCL↔Vulkan 的"官方"桥就是 clvk/clspv |
| 6 | Termux 生态 | **现成方案成熟** | `clinfo`、`ocl-icd`、`clvk`、`opencl-vendor-driver`、`mesa-vulkan-icd-freedreno`(Turnip)、`vulkan-loader-generic`、`llama-cpp`(含 opencl/vulkan 后端子包) 全部在官方仓库（2026-10 有更新） |

---

## 0. 本机实测实录（最关键证据，2026-10-14）

### 0.1 vendor OpenCL

| 尝试 | 结果 |
|---|---|
| `dlopen("/vendor/lib64/libOpenCL.so")`（绝对路径） | ❌ `dlopen failed: library "/vendor/lib64/libOpenCL.so" ... is not accessible for the namespace "(default)"` |
| `dlopen("/system/vendor/lib64/libOpenCL.so")` | ❌ 同上（本机 `/system/vendor` 只是指向 `/vendor` 的符号链接） |
| `dlopen("libOpenCL.so")`（按名字，无环境变量） | ⚠️ 加载到的是**发行版自带 ocl-icd**（`/data/data/cc.codroid/files/usr/lib/libOpenCL.so`）→ `clGetPlatformIDs` 报 **-1001**（CL_PLATFORM_NOT_FOUND_KHR） |
| `LD_LIBRARY_PATH=/vendor/lib64` + `dlopen("libOpenCL.so")` | ✅ 加载到 `/vendor/lib64/libOpenCL.so`，`clGetPlatformIDs=0`，`n=1`；**平台名 "QUALCOMM Snapdragon(TM)"，设备 "QUALCOMM Adreno(TM)"，版本 "OpenCL 3.0 Adreno(TM) 730"**；厂商驱动运行时又自行加载了 `/vendor/lib64/libgsl.so` |
| 把 `libOpenCL.so` 复制到 `~/workspace/` 私有目录，**按绝对路径 dlopen（无任何环境变量）** | ✅ 同样成功出平台（因为 `/data` 在 `(default)` 命名空间的 permitted paths 里；厂商库自己去找 `/vendor/lib64/libgsl.so` 也成功了） |
| `LD_LIBRARY_PATH=<只含 libOpenCL.so 副本的目录>` + 按名 dlopen | ✅ 成功（即 Termux 社区 `cp /vendor/lib64/libOpenCL.so .` + `LD_LIBRARY_PATH=.` 配方的原理） |
| `android_dlopen_ext("libOpenCL.so", RTLD_NOW, {flags=0x200, ns=android_get_exported_namespace("vndk" 或 "sphal")})` | ✅ 加载 `/vendor/lib64/libOpenCL.so` 成功，平台枚举成功。**用绝对路径 + 该命名空间也成功** |
| 同上但用 `__loader_android_get_exported_namespace`（`android_get_exported_namespace` 在 libdl 未导出） | ✅ 本机 `libdl.so` 导出了该符号（与 BOINC 的实测一致） |
| ⚠️ 坑：`flags` 必须写 **0x200**（`ANDROID_DLEXT_USE_NAMESPACE`）；写 0x8（是 `ANDROID_DLEXT_USE_RELRO`）会静默退化成普通 dlopen | 已在本机验证 |

SELinux 侧：`untrusted_app_27` 读 `/vendor/lib64/libOpenCL.so` 正常（read 测试通过，且上面多次加载/映射成功）——**失败都来自 linker namespace，不是 SELinux**。

### 0.2 机制解释（看本机 `/linkerconfig/ld.config.txt` 得出）

- 应用内 shell 的可执行文件在 `/data` 下 → 命中 `dir.system = /data`，进程使用 **[system] 命名空间组**：`namespace.default.isolated=true`，`search.paths=/system/lib64:/system_ext/lib64`，`permitted.paths` 含 `/data`、`/system/lib64/hw` 等，**不含 `/vendor/lib64`** → 这就是绝对路径 dlopen 失败的原因。
- 导出命名空间：本机 `sphal`、`vndk`、`rs`、`product`、`default` 都 `visible=true`，且 `sphal`/`vndk` 的 search paths 含 `/vendor/lib64` → `android_dlopen_ext` 路线成立。
- 这套规则与 AOSP 文档一致：`isolated=true` 时全路径加载要过 permitted paths 检查；`visible=true` 才可被 `android_get_exported_namespace` 拿到（[AOSP Linker namespace](https://source.android.com/docs/core/architecture/vndk/linker-namespace)）。
- `LD_LIBRARY_PATH` 为什么能绕过：bionic 在**非 AT_SECURE**进程启动时把 `LD_LIBRARY_PATH` 装进 default namespace 的 ld_library_paths（[linker_main.cpp](https://android.googlesource.com/platform/bionic/+/refs/heads/main/linker/linker_main.cpp)，注释 "Use LD_LIBRARY_PATH and LD_PRELOAD (but only if we aren't setuid/setgid)"），且"命名空间路径列表里找到的东西总是可访问"。JNI 进程内无法注入该变量（进程启动时已固定），所以 JNI 场景要走 manifest 或导出命名空间。

### 0.3 vendor 库的依赖解析（回答"DT_NEEDED 怎么解决"）

`readelf -d /vendor/lib64/libOpenCL.so`：`NEEDED = libcutils.so, libvndksupport.so, libc++.so, libc.so, libm.so, libdl.so`（SONAME=`libOpenCL.so`）。这批全是 LLNDK/VNDK-SP，在 `/system/lib64` 可达，所以**依赖不是问题**；真正拖后腿的 `libgsl.so` **不在 DT_NEEDED**，是厂商库运行期自己通过导出命名空间机制加载的（实测即使副本目录里没有 libgsl 也能跑）。另外该库自带 ICD 入口（`nm -D` 可见 `clIcdGetPlatformIDsKHR`、`qCLDrvAPI_*/qCLDefaultAPI_*`），即 Qualcomm 的 libOpenCL.so 是"loader+驱动"合体，不需要独立的 Khronos ICD 文件。
（注：本机发行版的 ocl-icd 走 `/etc/OpenCL/vendors` 的 ICD 文件路线实测报 -1001，原因未查明（可能与其编译的 vendordir 有关）——**推荐直接用上面的"直接加载"路线**。）

### 0.4 vendor Vulkan

- `dlopen("/vendor/lib64/hw/vulkan.adreno.so")` 绝对路径：❌ 同 namespace 报错。
- `dlopen("/system/lib64/libvulkan.so")`（系统 Vulkan loader）+ `vkCreateInstance`+`vkEnumeratePhysicalDevices`：✅ 枚举到 **"Adreno (TM) 730"，apiVersion=1.1.128**（driverVersion 0x80267060），实际映射了 `/vendor/lib64/hw/vulkan.adreno.so`、`libllvm-glnext.so`。**应用内 shell 可无 root 用厂商 Vulkan**（这也是所有 Android Vulkan 应用的常规路径）。

---

## 1. 直接 dlopen vendor 驱动（路径 1）

### 1.1 各版本限制的实际内容

| Android 版本 | 变化 |
|---|---|
| **7.0** | 引入 linker namespace；普通 app 只能加载 NDK 公共库/白名单；私有库加载报 `... is not accessible for the namespace "classloader-namespace"`；targetSdk≤23 的库"暂时可用"（有 logcat 警告）。（[官方 Android 7.0 变更](https://developer.android.com/about/versions/nougat/android-7.0-changes)） |
| **8.0** | Treble：vendor 分区；vendor 共享库可由 SoC 厂通过 `/vendor/etc/public.libraries.txt` 加白（7.0 起）；（AOSP）公共库里不得依赖非 VNDK-SP/LLNDK 系统库；（[AOSP adding native libraries](https://source.android.com/devices/tech/config/namespaces_libraries)） |
| **9.0** | 设备厂可加 `lib*COMPANY.so` 形式白名单；VNDK 命名空间；9+ 设备强制 VNDK linker config |
| **10** | 规则基本延续（未见新的对外限制） |
| **11** | ld.config 改为**运行时生成**到 `/linkerconfig`（本机即 `/linkerconfig/ld.config.txt`，实测存在）；`android_get_exported_namespace` 从 libdl 移成 libc 私有（[fadeevab 分析](https://fadeevab.com/accessing-system-private-api-through-namespace/)，2018-08-05；Android 11 补丁用 `__loader_` 前缀符号或偏移法绕过——本机 `__loader_android_get_exported_namespace` 可直接 dlsym） |
| **12** | **targetSdk≥31 的 app 默认不能加载非 NDK 库，必须显式声明** `<uses-native-library android:name="libOpenCL.so"/>`；targetSdk≤30 不受限（[官方行为变更](https://developer.android.com/about/versions/12/behavior-changes-12)，页面更新于 2026-10-01；[manifest 元素文档](https://developer.android.com/guide/topics/manifest/uses-native-library-element)，API 31 引入，需 Gradle≥7.2） |
| **13/14/15** | 未见新增限制的官方文档；**本机 Android 15 实测行为与 12 起的规则一致**；Android 15 新增：vendor 公共库可放在 vendor APEX 中用 `provideNativeLibs` 声明（AOSP 页） |

要点：**`uses-native-library` 只作用于 zygote 出来的 app/JNI 进程的 classloader 命名空间**。应用内 shell `fork/exec` 出来的子进程（本次场景）按可执行文件路径走 ld.config 的 `[system]` 段，**不受该限制**（本机实测：无任何 manifest 相关配置也能加载 vendor 库）。

### 1.2 实测成功的知名案例（网上证据）

- **BOINC Android 版**（2024-12-04 起）：`dlopen` 失败后改用 `__loader_android_get_exported_namespace` + `android_dlopen_ext`，在 Samsung S24 Ultra 上成功（输出 "Number of OpenCL platforms: 1"）；Termux 里 `LD_LIBRARY_PATH=/system/vendor/lib64` 能 dlopen 但 `clGetPlatformIDs` 报 -1001。👉 [BOINC/boinc#5931](https://github.com/BOINC/boinc/issues/5931)
- **OpenCLCapsViewer（Sascha Willems 的 Android 移植）**：Android 13 上找不到 libOpenCL.so，修法是 manifest 加 `<uses-native-library>`（Gradle≥7.2），2025-03-23 合并关闭。👉 [OpenCLCapsViewer#16](https://github.com/SaschaWillems/OpenCLCapsViewer/issues/16)
- **Termux 社区标准玩法**：`cp /vendor/lib64/libOpenCL.so .`（或某目录）+ `LD_LIBRARY_PATH=. clinfo -l` → 显示 `Platform #0: QUALCOMM Snapdragon(TM) / Device #0: QUALCOMM Adreno(TM)`；`LD_LIBRARY_PATH=. ./llama-server -ngl 200 ...`；注意若 `LD_LIBRARY_PATH=/vendor/lib64` 全量会导致 Termux 库冲突（`cannot locate symbol __emutls_get_address`），所以推荐"只复制一个 libOpenCL.so"。👉 [llama.cpp discussion #5507](https://github.com/ggml-org/llama.cpp/discussions/5507)、[termux-app#3885](https://github.com/termux/termux-app/issues/3885)
- **clinfo 上游自带 Android 支持**：Makefile 有 `ANDROID_VENDOR_PATH=/vendor/lib64`，生成一个设置 `LD_LIBRARY_PATH` 的 wrapper 脚本再调 `clinfo.real`（Termux 包改用 `OS=Linux`+ocl-icd 路线，见其 [build.sh](https://github.com/termux/termux-packages/tree/master/packages/clinfo)）。👉 [Oblomov/clinfo](https://github.com/Oblomov/clinfo)
- **通用绕过库**：xDL（2.4.0，README 声称可绕过 7.0+ 命名空间限制，支持到 Android 17）👉 [hexhacking/xDL](https://github.com/hexhacking/xDL)；**fadeevab 的 JNI→android_create_namespace→android_dlopen_ext 方案**（含 demo 仓库 `fadeevab/android-custom-jni-namespace`）👉 [文章](https://fadeevab.com/accessing-system-private-api-through-namespace/)。
- "OpenCL Info"类 app（Xavier Hallade 2013 年代）在 Adreno 上能显示 Qualcomm OpenCL 平台——年代老，仅作旁证。

### 1.3 可行性：**高**（Adreno 上）。components & 坑

- 需要：无额外组件（vendor 驱动自带）；可选 `clinfo`/`ocl-icd`（但 ocl-icd 的 ICD 文件路线在 Adreno 上不一定成，见 0.3）。
- 四种可用配方（按场景）：
  1. **应用内 shell（本场景）最简单**：把 `/vendor/lib64/libOpenCL.so` 复制进应用私有目录，直接按绝对路径 `dlopen`（本机✅）；或 `LD_LIBRARY_PATH=<该目录>` 后按名加载（本机✅；也是 Termux 社区验方）。
  2. `LD_LIBRARY_PATH=/vendor/lib64`（本机✅；注意可能遮蔽同名库）。
  3. 任何进程内：`android_dlopen_ext` + `__loader_android_get_exported_namespace("vndk")` + `ANDROID_DLEXT_USE_NAMESPACE=0x200`（本机✅，BOINC 在真 app 里✅）。
  4. **JNI 内最正统**：manifest `<uses-native-library android:name="libOpenCL.so" android:required="false"/>`，然后按名字 `System.loadLibrary("OpenCL")`/`dlopen("libOpenCL.so")`（targetSdk≥31 必须；OpenCLCapsViewer✅）。全路径加载在 JNI 的 classloader 命名空间下大概率被拒（与本机 `(default)` 现象同源；未在 JNI 上逐条实测）。
- 坑：绝对路径直接加载不行（除非经上面机制）；`flags` 常量坑（0x200≠0x8）；`LD_LIBRARY_PATH` 全局设 `/vendor/lib64` 会破坏 Termux 系发行版自带库；Xclipse（三星）用户需要 `LD_LIBRARY_PATH=/vendor/lib64:/vendor/lib64/hw`（#5507）；如果 ocl-icd+ICD 文件路线报 -1001 属正常（本机也是），不要在这条路上恋战。

---

## 2. clvk（OpenCL 3.0 on Vulkan）（路径 2）

- **状态**：Google 主导、Apache-2.0；仓库 454 stars、128 open issues、无正式 release；**2026-10-09 仍有提交**（如 "Add a device_name config option"、CI 升 NDK r30），维护活跃。👉 [kpet/clvk](https://github.com/kpet/clvk)
- **Android 构建**：README 明确"可用 Android NDK 构建"（`-DCMAKE_TOOLCHAIN_FILE=.../android.toolchain.cmake -DANDROID_ABI=arm64-v8a -DVulkan_LIBRARY=<ndk>/.../libvulkan.so`）；依赖 clspv/libclc。**Termux 官方打包了 clvk**（2026-10-05 commit，`-DCLVK_CLSPV_ONLINE_COMPILER=ON`，安装到 `$PREFIX/lib/clvk/libOpenCL.so` 并注册 ICD。👉 [termux 包](https://github.com/termux/termux-packages/tree/master/packages/clvk)
- **Vulkan 要求**（读源码 `src/device.cpp`）：大批扩展按需启用：`VK_KHR_8bit_storage/16bit_storage/shader_float16_int8/variable_pointers/vulkan_memory_model/global_priority`、`VK_EXT_descriptor_indexing/buffer_device_address` 等；<1.2 时补 `VK_KHR_spirv_1_4+shader_subgroup_extended_types`，<1.1 时才要 `VK_KHR_storage_buffer_storage_class`。实践上 **Vulkan 1.2+ 驱动最省心；1.1+扩展也行**（README 树莓派一节只提 1.1）。**Turnip（Vulkan 1.4，Mesa 25.0 起）完全达标**。
- **Android + Turnip 实测案例**：
  - 韩语实测（Adreno 840，2026-05）：OpenCL 走"Vulkan 驱动 + clvk"，FP32 **3.941 TFLOPs（Turnip）vs 3.667 TFLOPs（vendor 驱动经 bionic-vulkan-wrapper）**，且"OpenCL 结果与原生 Vulkan compute 误差内一致"。👉 [meeco 帖 41413883](https://meeco.kr/mini/41413883)、[41415521](https://meeco.kr/ITplus/41415521)
  - llama.cpp #17456（Adreno 740，2025-11→2026-02）：clvk 在 Turnip 上确实跑起来了（设备串 "Turnip Adreno (TM) 740v3 (OpenCL 3.0 CLVK on Vulkan v1.4.328)"），但 **llama.cpp 的 OpenCL 后端因缺 subgroups 拒收该设备**（"device does not support subgroups (cl_khr_subgroups or cl_intel_subgroups)"），强改检查后模型加载出错。👉 [#17456](https://github.com/ggml-org/llama.cpp/discussions/17456)
  - 应用内自带 clvk 的先例：**KataGO_Android**（minSdk29/targetSdk35，APK 内置或导入 ~75MB 的 clvk `libOpenCL.so`，GPU 模式=clvk，失败自动回退 CPU）。👉 [ChuiShui233/KataGO_Android](https://github.com/ChuiShui233/KataGO_Android)
  - AOSP 树内也有 `external/clvk`（android16/17 分支、CTS/VTS 标签），说明 Google 在平台侧维护它。👉 [android.googlesource.com/.../external/clvk](https://android.googlesource.com/platform/external/clvk/)
  - IWOCL 2026 的 OpenCL SOTU 幻灯片提到 clvk 已被出货 Android 应用/引擎使用（如 Adobe Premiere Rush，~20 万行 kernel 代码）——*注：我未逐字核对 PDF 原文，仅有检索摘要*。👉 [IWOCL 2026 幻灯片](https://www.iwocl.org/wp-content/uploads/IWOCL-2026-Ashbaugh-OpenCL_SOTU26.pdf)
- **兼容性/性能/坑**：README 列限制：每 context 仅一 device、无 out-of-order 队列、无 native kernels、受 clspv 限制；已知应用支持表：clinfo/clpeak/CLBlast/BOINC/TFLite ✔，**Blender 明确标注 "Untested"**；hashcat/x264 等有失败。👉 [supported-applications.md](https://github.com/kpet/clvk/blob/main/docs/supported-applications.md)。另外 subgroup 类应用（llama.cpp OpenCL）在 Turnip 上不可用；有些驱动 shader 编译问题（koboldcpp 报告）。
- **结论：中-高**。要什么：clvk（+clspv，官方包内自带）+ Vulkan 1.2+ 驱动（Turnip 推荐：Termux `mesa-vulkan-icd-freedreno`+`vulkan-loader-generic`）。适合给 clinfo/CLBlast/自研 OpenCL 程序提供"跨厂商"的 OpenCL 3.0；不适合直接喂 llama.cpp 的 OpenCL 后端（subgroups）。

---

## 3. rusticl（路径 3）

- **官方文档**：Rust 写的 Gallium OpenCL（3.0/3.1）；需要 `RUSTICL_ENABLE=<driver>` 显式启用（除非发行版用 `gallium-rusticl-enable-drivers` 默认打开）。👉 [docs.mesa3d.org/rusticl.html](https://docs.mesa3d.org/rusticl.html)
- **对 freedreno/Adreno 的支持（Linux 侧，官方）**：XDC 2025/2026 状态更新——**Freedreno 已默认启用 rusticl**、OpenCL 3.1、FP16 已在 freedreno 上支持；Qualcomm 的 XDC 2026 演讲把 "Rusticl 默认启用+OpenCL 3.1" 列为对 Adreno 800 系的支持现状；更早（FOSDEM 2024，Baryshkov "Why not run OpenCL-accelerated LLM on your phone"）是 WIP 阶段（需 `RUSTICL_ENABLE=msm`，跑过 TinyGrad demo）。👉 [Phoronix: Rusticl 2026 回顾](https://www.phoronix.com/news/Rusticl-2026)、[Phoronix: FP16](https://www.phoronix.com/news/Rusticl-Mesa-25.2-FP16)、[FOSDEM 2024 slides](https://fosdem.org/2024/events/attachments/fosdem-2024-3364-why-not-run-opencl-accelerated-llm-on-your-phone-/slides/22383/Why_not_run_OpenCL-accelerated_LLM_on_your_phon_nK2DudB.pdf)
- **Android 上的现状**：Termux 仓库**有** `mesa-opencl-icd-rusticl`（26.2.5，2026-10），但其 `mesa` 编译参数是 `-Dgallium-drivers=llvmpipe,softpipe,virgl,zink`（**不含 freedreno gallium**）→ 该包只能跑 llvmpipe/zink/virgl。理论上可以"**rusticl→zink→Turnip**"（zink 在 rusticl 默认启用名单里），但**没有任何人晒出这个组合在 Android 上跑通的记录——未证实**。Termux 的 Turnip 是 `-Dvulkan-drivers=...freedreno`+`-Dfreedreno-kmds=msm,kgsl` 编出来的（只影响 Vulkan 侧）。👉 [termux mesa build.sh](https://github.com/termux/termux-packages/tree/master/packages/mesa)
- **要自己造的话**：需要在 Android 上编一套启用 `freedreno` gallium（kgsl 后端）+rusticl 的 Mesa（KGSL 用户态，无需 root，原理同 Turnip）；工程量大、无先例。
- **结论：低-中**。上游官方支持 Adreno（Linux），Android 无现成可用案例；短期不建议作为主路径。

---

## 4. 直接 Vulkan compute 直通（路径 4）

### 4.1 对 llama.cpp：**高**（本机环境可用系统 loader）

- 本机已证明：应用内 shell 里 `dlopen("/system/lib64/libvulkan.so")`→`vkCreateInstance`→枚举到 Adreno 730（vendor，1.1.128）。所有 Android 应用的 Vulkan 都是这条链路（厂商 HAL `vulkan.adreno.so` 由系统 loader 经 sphal 命名空间加载，不需要 root）。
- **硬门槛**：ggml Vulkan 后端源码里明确 `"ggml_vulkan: Error: Vulkan 1.2 required."`（ggml-vulkan.cpp 5192/5199 行）。本机 vendor 驱动 **1.1.128 < 1.2 → 不能直接用 vendor 驱动跑 llama.cpp Vulkan**；**Turnip 是 Vulkan 1.4（Mesa 25.0 起，2025-02-19 公告）**，满足。👉 [Mesa 25.0 公告](https://lists.freedesktop.org/archives/mesa-dev/2025-February/226464.html)
- **已跑通案例**：
  - Termux 傻瓜指南（骁龙 8 Gen 3）：`pkg install mesa-vulkan-icd-freedreno vulkan-loader-generic vulkan-tools llama-cpp llama-cpp-backend-vulkan`，`llama-cli -m ... -fa on -co on -ngl 99`。👉 [shouchen 博客（2025-10/2026-01）](https://shouchen.blog/post/202510011615)
  - 实测数据（Adreno 830 + Turnip，2026-10）：pp64 **45.76 t/s(vs CPU 37.10)**，tg32 9.31（vs 9.86，略降），**CPU 占用降 6.6×**。👉 [ArborPopuli/termux-harness](https://github.com/ArborPopuli/termux-harness)
  - Adreno 750 + Turnip：Qwen3-8B 约 7 t/s（[#17456 回复](https://github.com/ggml-org/llama.cpp/discussions/17456)）；Adreno 750 vendor 驱动崩溃、Turnip 能加载（[#9464](https://github.com/ggml-org/llama.cpp/discussions/9464)）。
  - **vendor 驱动的坑**（Adreno 830，2026-10-01）：vendor 驱动无 vk_icd 符号（Android vendor HAL 形态），且 Termux 分发时缺 `libllvm-qgl.so` → SIGABRT；补齐后 `-ngl 1` 可用，但 `-ngl≥2` 在 q4_K 上 `vkCreateComputePipelines: ErrorUnknown`（同 SPIR-V 在 Turnip 正常）。👉 [#29786](https://github.com/ggml-org/llama.cpp/issues/29786)；另有 #12421（2025-03，维护者当时称"Qualcomm shader 编译器已知问题，目前 Adreno 根本不行"，2026-09 有人补充"同样 SPIR-V 在真实 app 上下文里能成功"，疑似 Termux 进程环境问题）。
- 结论：**llama.cpp 用 Vulkan 后端 = 上策**；本机（1.1.128）必须配 Turnip（或升级 vendor 驱动/换机）；OpenCL 后端则反过来要用 vendor OpenCL（见路径 1）——clvk 版因 subgroups 不可用。

### 4.2 对 Blender：**低**（不存在 GPU compute 后端）

- Cycles **在 Blender 3.0 就删除了 OpenCL**（官方开发者文档原话 "OpenCL support was removed in Blender 3.0"，由 HIP/Metal/SYCL 等替代）。👉 [Blender dev docs](https://projects.blender.org/LukasStockner/blender-developer-docs/src/commit/67cccc32d28b1b2718a49b86ba58afe6e216d8a0/docs/trash/source/cycles/opencl.md)
- 现状 Cycles GPU 后端 = CUDA/OptiX/HIP/oneAPI/Metal；**没有 Vulkan compute**，且 2025-08 官方论坛回复明确"Cycles 没有用 Vulkan 的计划"。👉 [Blender Artists 帖](https://blenderartists.org/t/system-render-options/1605071/4)
- Blender 4.3+ 的"实验性 Vulkan 后端"只服务 **EEVEE/视口**（图形管线）——在 Android 上对应案例：非官方 Android 移植 **Blender 5.3-alpha（2026-09，arm64、强制要 Vulkan、还附 Turnip 构建；Cycles 可用但没写 GPU 计算后端）**👉 [blenderandroid.github.io](https://blenderandroid.github.io/)；Termux 原生 Blender 4.5 跑 Vulkan 后端时 **Turnip 渲染会无限卡死，用 bionic-vulkan-wrapper（vendor Vulkan+X11 WSI）反而稳定**（2026-03-15，S26U 实测）。👉 [meeco 帖 41293552](https://meeco.kr/mini_hot/41293552)
- 结论：**Blender CLI 在 Adreno 上别指望 GPU 渲染/计算**（除非未来 Cycles 有 Vulkan 后端）。若目标是"让某个程序用上 Adreno"，优先 llama.cpp（Vulkan/OpenCL 双后端俱在）而不是 Blender。

---

## 5. 其他路径（简）

- **pocl**：MIT，CPU 实现（OpenCL 3.0），**Android 支持自 0.11（2015-03）**，有社区 Android 交叉编译包（repology 上 7.x）；仅 CPU，Termux 官方仓库无此包（本报告已核实 404）。👉 [pocl 0.11](https://portablecl.org/pocl-0.11.html)、[repology](https://repology.org/project/pocl/packages)。可行性：中（但价值≈跑在 CPU 上，意义有限）。
- **ACL（Arm Compute Library）**：仅 Arm CPU/Mali；clvk 的支持表里直接标 "not supported"；与 Adreno 无关。
- **"OpenCL-on-ANGLE"**：**不存在这个东西**。ANGLE 是 GLES→Vulkan 的桥；OpenCL↔Vulkan 的正牌桥是 **clvk + clspv**（Google）以及 **rusticl-over-zink**（Mesa）。Khronos 的教程章节也把 clvk 作为移动端 OpenCL 的标准做法。👉 [Khronos Vulkan tutorial: OpenCL on Vulkan](https://github.khronos.org/Vulkan-Site/tutorial/latest/Advanced_Vulkan_Compute/05_OpenCL_on_Vulkan/05_clvk_and_layering.html)
- 另：RenderScript（曾是 Android 上的 OpenCL 消费者）自 Android 12 起废弃，不再相关。

---

## 6. Termux 生态现状（2026-10-14 实测查询 packages.termux.dev）

官方仓库（termux-main/aarch64）现有：`clinfo 3.1.26.09.26`、`ocl-icd 2.3.5`、`opencl-headers 2026.05.29`、**`opencl-vendor-driver 0.3-1`**、**`clvk 0.0.20261005.162530`**、`mesa 26.2.5`（`-Dgallium-rusticl=true`）、**`mesa-opencl-icd-rusticl 26.2.5`**、**`mesa-vulkan-icd-freedreno 26.2.5`（Turnip）**、`vulkan-loader-generic 1.4.365`、`vulkan-tools 1.4.365`、`llama-cpp 0.6.0`（子包 `llama-cpp-backend-opencl` 和 `llama-cpp-backend-vulkan`，后者 SUGGESTS `vulkan-loader-generic, mesa-vulkan-icd-freedreno`）。包源码：👉 [clinfo](https://github.com/termux/termux-packages/tree/master/packages/clinfo)、[ocl-icd](https://github.com/termux/termux-packages/tree/master/packages/ocl-icd)、[opencl-vendor-driver](https://github.com/termux/termux-packages/tree/master/packages/opencl-vendor-driver)、[clvk](https://github.com/termux/termux-packages/tree/master/packages/clvk)、[llama-cpp](https://github.com/termux/termux-packages/tree/master/packages/llama-cpp)、[mesa](https://github.com/termux/termux-packages/tree/master/packages/mesa)。

注意 `opencl-vendor-driver` 的 build.sh 自己标注的厂商支持表里 **Adreno 一栏写"不支持"**（"Qualcomm Adreno / cl_khr_icd: n / Supported: n"；Mali、PowerVR 为 y）——即"通过 ocl-icd 注册 ICD"路线对 Adreno 不工作；但本报告实测的"直接加载 vendor libOpenCL.so"路线对 Adreno 是通的。社区"能跑"的记录（`clinfo -l` 显示 QUALCOMM/Adreno、llama.cpp `-ngl`）都来自 LD_LIBRARY_PATH/复制库这条线（#5507、#3885）。

本机发行版现状（只读检查）：已带 ocl-icd（`$PREFIX/lib/libOpenCL.so`，SONAME=libOpenCL.so）、Vulkan loader 1.4.365、lavapipe ICD、Mesa 26.2.4 gallium（含 zink）、libdrm_freedreno；**未装** clinfo/clvk/Turnip；`apt` 源列表为空，本地也没下包索引 → `pkg install ...` 能否直接用**未验证**（需要先配好源或自行编译）。

---

## 7. 未证实 / 存疑清单（避免当结论用）

- clvk + **本机 vendor 驱动（Vulkan 1.1.128）** 跑 OpenCL：未测（clvk 需要的那批扩展 1.1.128 未必齐）；clvk+Turnip 有案例。
- **rusticl 在 Android 上跑 Adreno**（含 rusticl→zink→Turnip）：无任何实证（上游 Linux 侧支持已默认启用）。
- Blender（2.9x 老版本）经 clvk 用 OpenCL 渲染：clvk 官方支持表把 Blender 列为 "Untested"，无案例。
- `uses-native-library` 是否让 **JNI 内全路径 dlopen** 也成功：未实测（按文档/本机现象推测会被拒；推荐按名加载）。
- ocl-icd+ICD 文件路线在本机报 -1001 的根因（可能为 vendordir 编译差异或 ICD 兼容性）：未查明。
- IWOCL 2026 SOTU 中 clvk 被 Adobe Premiere Rush 使用的说法：仅来自检索摘要，未逐字核对。
- 韩语帖称 Termux 环境 "OpenCL 3.3"：与 OpenCL 版本命名不符，疑似笔误/口径不明（同一作者其它数据可参考）。
- 本机 `pkg/apt install` 是否可用：未验证。

---

## 8. 给本项目（app uid shell 场景）的落地建议

1. **clinfo/自研 OpenCL 程序**：先把 `/vendor/lib64/libOpenCL.so` 复制进应用私有目录（本机私有目录绝对路径加载已实测成功），`LD_LIBRARY_PATH=<该目录>` 运行即可；不要走 ocl-icd ICD 文件路线（Adreno 上易 -1001）。JNI 内则用 manifest `<uses-native-library>` + 按名加载，必要时 `android_dlopen_ext`（0x200 + `__loader_android_get_exported_namespace("vndk")`）。
2. **llama.cpp**：优先 Vulkan 后端 + Turnip（本机 vendor 驱动 1.1.128 达不到 ggml 的 Vulkan 1.2 硬要求）；若用 OpenCL 后端则必须 vendor OpenCL（clvk 缺 subgroups 被拒）。
3. **OpenCL-over-Vulkan 兜底**：clvk（Termux 有 10 月新包；或 app 内自带，参考 KataGO），在 Turnip（Vulkan 1.4）上实测性能≈原生 Vulkan；不要期待它在 llama.cpp OpenCL 后端上工作。
4. **Blender**：GPU 计算不可行（Cycles 无 OpenCL/Vulkan compute 后端）；只可作为图形/视口场景探讨（Vulkan+Turnip 或 vendor+wrapper，且 Turnip 有卡死报告）。
