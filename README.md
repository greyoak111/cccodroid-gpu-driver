# cccodroid-gpu-driver

**免 root，让 Android 上的命令行程序直接用上高通 Adreno GPU。**
开源驱动 Turnip（Vulkan 1.4）+ Mesa zink（OpenGL/GLES）+ 厂商 OpenCL，
全部进程级生效：不改系统分区、不装模块、不需要 root。

两套，各管一类程序：

| | 给谁用 | 入口 | 本机实测 |
|---|---|---|---|
| **bionic 侧**（Termux 那套） | `$PREFIX/bin` 里的 CLI 程序 | `gpu-run` / `gpu-info` | Turnip **Vulkan 1.4.354** · zink GL · 厂商 OpenCL 3.0 |
| **glibc 侧**（Linux arm64） | Debian 包、glibc 二进制（Blender 之类） | `lgpu-run` / `lgpu-info` / `lgpu-cc` | Turnip **Vulkan 1.3.289** · 本机直接编 glibc 程序 |

```
你的程序 → gpu-run / lgpu-run → Turnip（Vulkan）→ /dev/kgsl-3d0 → Adreno
                              └ zink（GL→Vulkan 转译）→ 同上
                              └ 厂商 OpenCL（bionic）/ clvk（glibc）→ 同上
```

这是 cccodroid 组件市场里 [`gpu-driver`](recipe/recipe.json) 组件的上游仓库：
应用里一键装的就是这里的脚本，本仓库额外提供完整版（HAL 通道、`gpu-switch`）、
glibc 侧组件（[`glibc/`](glibc/)）和调研文档。

## 实测（Lenovo TB320FC / Legion Y700 2023）

| 项 | 结果 |
|---|---|
| 设备 | 骁龙 8+ Gen 1（SM8475）· Adreno 730 · Android 15 · 内核 5.10 |
| 厂商驱动 | Adreno (TM) 730 · **Vulkan 1.1.128** · GLES 3.2 |
| **Turnip（默认）** | Turnip Adreno (TM) 725 · **Vulkan 1.4.354** · `turnip Mesa driver` |
| zink（GL） | `GL_RENDERER: zink Vulkan 1.4(Turnip Adreno (TM) 725 (MESA_TURNIP))` |
| 渲染自测 | 建 FBO → 清屏 → 读回像素 `(64,128,191,255)` = 期望值 → **PASS** |
| OpenCL | 厂商驱动 · OpenCL 3.0 · 向量加 kernel **PASS** |
| 组件包 | 11 个包 · 下载 5.6 MB · 解包 39.4 MB |

「渲染自测」不是看能不能 dlopen —— 是真建帧缓冲、清屏、把像素读回来比对，
所以 `gpu-info` 说 PASS 就是 GPU 真的算出了东西。

## 为什么厂商驱动不够，非要 Turnip

- 厂商 Vulkan 只有 **1.1**（本机 1.1.128）。llama.cpp 的 Vulkan 后端硬性要求 **1.2**，
  新一点的 Vulkan 程序普遍要 1.3+ —— 一律被挡在门外。
- 系统 Vulkan loader **不认 `VK_DRIVER_FILES`**，没法直接换驱动。
- Freedreno 的原生 GL 驱动（msm）需要 `/dev/dri`，而应用进程根本看不到它（SELinux/权限），
  所以 GL 只能走 **zink**（GL→Vulkan）→ Turnip → KGSL。

## 两条免 root 通道（都实测可用）

应用进程 `dlopen("/vendor/lib64/...")` 会被 linker namespace 挡掉
（`not accessible for the namespace "(default)"`）。绕开它有两条正路：

| | 通道 A：标准 ICD（默认） | 通道 B：HAL 驱动（可选） |
|---|---|---|
| 机制 | `VK_DRIVER_FILES` 指向组件目录里的 ICD，用 `$PREFIX` 的 Khronos loader | `GraphicsEnv::setDriverPathAndSphalLibraries()` 指定驱动目录，系统 loader 从那里加载 HAL 风格驱动 |
| 驱动来源 | Termux 官方 `mesa-vulkan-icd-freedreno` | AdrenoToolsDrivers（社区 Turnip，HAL 形态） |
| 用在 | 链 `-lvulkan` 的普通 CLI 程序、zink | 只认系统 `/system/lib64/libvulkan.so` 的程序 |
| 本机结果 | Turnip · Vulkan **1.4.354** | Turnip · Vulkan **1.4.335** |

通道 B 的载荷**不随本仓库分发**（见「许可证」）：用 `install.sh --hal-zip <上游 zip>` 现取现装，
垫片 `src/gpu_bootstrap.cpp`（40 行，只调 `libgraphicsenv.so`）现场编译。

## 装

**方式一（推荐）**：在 cccodroid 应用 → 插件市场里装 `gpu-driver`。

**方式二（完整版）**：

```sh
./install.sh --dry-run        # 先看它要做什么
./install.sh --fetch          # 装 Turnip（从 Termux 官方仓库取，校验 sha256）
./install.sh --fetch --hal-zip ~/Turnip_v26.0.0_R8.zip   # 顺带装 HAL 通道
gpu-info                      # 自检
```

完整版比市场版多两样：可选 HAL 通道、`gpu-switch`（把 `$PREFIX/lib/libOpenCL.so`
换成厂商驱动，带备份可还原 —— 会改 `$PREFIX` 里的文件，慎用）。

## 用

```sh
gpu-info                                    # 自检；退出码 0 = Turnip 可用
gpu-run vkmark                              # Vulkan（Turnip）
gpu-run vulkaninfo --summary                # 看驱动名/版本
gpu-run llama-cli -m model.gguf -ngl 99     # llama.cpp 的 Vulkan 后端
gpu-run -z --surfaceless glmark2-es2 --off-screen   # 离屏 OpenGL（无显示服务器）
gpu-run --opencl clinfo                     # 厂商 OpenCL（LD_LIBRARY_PATH，不动 $PREFIX）
gpu-run -m hal <程序>                        # 通道 B（装了载荷才可用）
gpu-run --vendor <程序>                      # 什么都不注入
```

细节见 [skill/SKILL.md](skill/SKILL.md) —— 那份也会作为 Claude 的 skill 装到设备上。

## glibc / Linux arm64 侧

给 **glibc 程序**（Debian 包、glibc 构建的二进制）用。包取自
[Termux 官方 glibc 仓库](https://packages.termux.dev)（`termux-glibc`），装到 `$PREFIX/glibc/` 下：

```sh
lgpu-info                                   # 自检
lgpu-run vulkaninfo --summary               # glibc 侧的 Vulkan 驱动
lgpu-run ./你的程序                          # 用 Turnip 跑
lgpu-run -z ./GL程序 -L <debroot 的库目录>    # OpenGL 走 zink（需要 glibc 版 Mesa）
lgpu-cc hello.c -o hello                    # 在本机编 glibc 程序（C++ 自动换 clang++）
```

本机实测（TB320FC）：

```
$ lgpu-info
===== Turnip（glibc 侧）=====
GPU0: deviceName = Turnip Adreno (TM) 725   apiVersion = 1.3.289
      driverInfo = Mesa 24.2.6.termux-glibc-0

$ lgpu-cc vkglibc.c -O2 -o vkglibc -lvulkan && lgpu-run ./vkglibc
GPU0  Turnip Adreno (TM) 725
      api=1.3.289  vendor=0x5143 device=0x7030002  集成 GPU
```

两个只有 glibc 侧才会碰到的坑（都已写进脚本 / SKILL.md）：

- **必须摘掉 bionic 的 `LD_PRELOAD`**（cccodroid 的 shell 挂着 termux-exec 垫片）：glibc 的
  ld.so 会跨 libc 继承它，然后报 `.../glibc/lib/libc.so: invalid ELF header` —— 像是 glibc 坏了，
  其实只是这个垫片。`lgpu-run` 自动处理。
- **库路径不能掺 bionic**（`$PREFIX/lib` 是 bionic 的，符号版本 `LIBC`/`LIBC_N`）——
  掺进去会满屏 `version 'LIBC' not found`。要加库用 `-L` 显式加。

**在本机编 glibc 程序**：本机 clang 是 bionic 的，交叉到 glibc 只差 GCC 运行时的
`crtbegin*`/`crtend*`/`libgcc.a`/`libgcc_eh.a`（就是 libgcc-14-dev 的那几件）。
`lgpu-cc --setup` 从 Termux 官方仓库的 `gcc-glibc` 包里只挑那几百 KB（核对 SHA256），
头文件/库/链接脚本用 base 里已有的 `glibc` 包 —— 于是 `lgpu-cc` 一行就能编。

## 支持矩阵与边界

| 代际 | Turnip | 说明 |
|---|---|---|
| a5xx（Adreno 506/509/512…） | ❌ 永远没有 | 上游已定论，只能厂商 blob |
| a6xx（618/640/650/660…） | ✅ Vulkan 1.3 | |
| **a7xx（710–750）** | ✅ Vulkan 1.4 | 本机 730；`TU_DEBUG=sysmem` 关 tiling 更稳（默认已设） |
| a8xx（810–840） | ⚠️ 实验 | Adreno 830 / 8 Elite 有 KGSL 提交失败报告，用 `--vendor` 兜底 |

其它注意：

- **只对高通有效**（依赖 `/dev/kgsl-3d0`）。别的 SoC 上 `gpu-info` 会直说。
- Android 16 起 OEM 可能对 GPU ioctl 加白名单，可能拒新驱动（本机 targetSdk 28 / Android 15，无此问题）。
- 静态链接的程序忽略 `LD_PRELOAD`（通道 B 无效，用默认通道）。
- **glibc 程序别用通道 B**：bionic 的 `LD_PRELOAD` 会跨 libc 边界被 glibc 的 `ld.so` 继承，行为不可预期。

## 目录

```
bin/gpu-run  bin/gpu-info  bin/gpu-switch   # bionic 侧入口（市场配方用同一份 gpu-run / gpu-info）
lib/probe.py                                # 自检探针（ctypes，无额外依赖）
lib/fetch_turnip.py                         # 从 Termux 官方仓库取 Turnip ICD
src/gpu_bootstrap.cpp                       # 通道 B 的 LD_PRELOAD 垫片源码
install.sh                                  # 完整版安装器（幂等）
recipe/                                     # cccodroid 组件市场配方 + 同步脚本
skill/SKILL.md                              # 给 Claude 的用法说明
glibc/                                      # glibc 侧：lgpu-run / lgpu-info / lgpu-cc + 配方
  bin/ lib/fetch-glibc-toolchain.py         #   └ 补齐 crt/libgcc，使本机 clang 能编 glibc 程序
.github/workflows/build-clvk.yml            # CI 编 clvk（glibc 版 OpenCL），产物带 sha256
docs/                                       # 调研与实践记录（见下）
```

## 文档

| 文档 | 内容 |
|---|---|
| [docs/RESEARCH.md](docs/RESEARCH.md) | 机制总报告：namespace 墙、两条通道、zink、OpenCL，以及全部实测数据 |
| [docs/BLENDER_CASE.md](docs/BLENDER_CASE.md) | 案例：Android 上的 Blender CLI（[blender-cli-android](https://github.com/greyoak111/blender-cli-android)） |
| [docs/ADRENOTOOLS_CASE.md](docs/ADRENOTOOLS_CASE.md) | Turnip 代际覆盖、AdrenoTools/libadrenotools 机制与支持矩阵 |
| [docs/OPENCL_CASE.md](docs/OPENCL_CASE.md) | 免 root 的 GPU 计算路径（OpenCL / Vulkan compute / clvk / rusticl） |

## 路线图

- [x] bionic 侧：两条 Turnip 通道 + zink + 厂商 OpenCL，真机验证
- [x] 组件市场上架配方（`gpu-driver`，PR 已开）
- [x] glibc 侧：Turnip + `lgpu-run`/`lgpu-info`，真机验证
- [x] 本机编 glibc 程序（补上 libgcc/crt 那几件，`lgpu-cc` 一行搞定）
- [ ] clvk 的 glibc 版（OpenCL over Vulkan）：CI 构建（`.github/workflows/build-clvk.yml`），
      设备上不编 —— clspv + LLVM + libclc 在 8 核手机上是小时级
- [ ] 往 cccodroid 主仓库 PR：组件市场放行 `kind: glibc`（`devkit.mjs` 一行白名单）

## 许可证与鸣谢

本仓库的脚本与文档：**MIT**。

第三方（均按各自许可证使用，**本仓库不重新分发**这些二进制，脚本只提供获取与配置的方法）：

- [Mesa](https://gitlab.freedesktop.org/mesa/mesa)（MIT）—— Turnip 与 zink 的出处
- [Termux 官方仓库](https://packages.termux.dev)（各包各自许可）—— 标准 ICD 形式的 Turnip、Mesa、Vulkan 工具
- [AdrenoToolsDrivers](https://github.com/K11MCH1/AdrenoToolsDrivers) —— HAL 形态的 Turnip 构建（仅在你显式 `--hal-zip` 时下载）
- [libadrenotools](https://github.com/bylaws/libadrenotools) —— 通道 B 的机制来源（本项目不依赖它，只是同一套思路）
- [lfdevs/mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container) —— glibc 侧用到的补丁版 Mesa

设备端权限说明：app 读 `/dev/kgsl-3d0` 是 AOSP 明文允许的
（`app.te: allow appdomain gpu_device:chr_file rw_file_perms`），本组件不需要任何提权。
