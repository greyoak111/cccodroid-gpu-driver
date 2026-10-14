---
name: gpu-driver-glibc
description: 让 glibc（Linux arm64）程序用上本机 Adreno GPU：Turnip Vulkan 1.4（glibc 侧）+ 可选 zink。用户要跑 Debian/glibc 的 Vulkan 或 OpenGL 程序（Blender 之类）、或问 glibc 程序能不能用 GPU 时使用。
---

# GPU（glibc 侧）

给 **glibc 程序**（Debian 包、glibc 构建的二进制）接上本机 Adreno GPU：`lgpu-run` 负责
把 glibc 运行时、Turnip 的 ICD、以及（可选）Mesa/zink 的环境拼对，再经 `ld-linux` 启动程序。

## 先自检

```sh
lgpu-info          # GPU / glibc 运行时 / Turnip / Mesa(zink) / clvk；退出码 0 = Turnip 可用
```

## 用法

```sh
lgpu-run vulkaninfo --summary              # 看 glibc 侧的 Vulkan 驱动
lgpu-run <你的 glibc 程序> [参数...]        # 默认注入 Turnip ICD
lgpu-run -z <GL 程序>                       # OpenGL/GLES 走 zink（需要 glibc 版 Mesa）
lgpu-run -L /path/debroot/usr/lib/aarch64-linux-gnu <程序>   # 追加库目录（Debian 依赖）
lgpu-run --icd <别的 icd.json> <程序>       # 用你自己那份更新版 Mesa 的 ICD
lgpu-run --vendor <程序>                    # 不注入 ICD
lgpu-run --direct <程序>                    # 不经 ld-linux，直接 exec（脚本、静态程序用）
```

## 在本机编 glibc 程序（要写代码时）

```sh
lgpu-cc hello.c -o hello            # C 直接编；C++ 自动换 clang++
lgpu-cc --setup                     # 只补齐工具链碎片（首次会自动做，约 84MB 下载、核对 SHA256）
lgpu-cc --show hello.c              # 只打印最终命令
./hello                             # 编出来直接跑（解释器已指向 $PREFIX/glibc/lib/ld-linux）
lgpu-run ./hello                    # 要 GPU 就套 lgpu-run
```

原理：本机 clang 是 bionic 的，交叉到 glibc 只差「GCC 的 crtbegin*/crtend*/libgcc」那几件
（就是 libgcc-14-dev 的内容，Termux 官方 glibc 仓库的 `gcc-glibc` 包里），`--setup` 只挑那几百 KB 出来。
头文件/库/链接脚本用 base 里已有的 `glibc` 包，动态链接器指到 `$PREFIX/glibc/lib/ld-linux-aarch64.so.1`。

- **`-L` 可以给多次**，也可以设 `CCODROID_LGPU_LIBS`（冒号分隔）。
- ⚠️ **库目录里不能有 bionic 的路径**（`$PREFIX/lib` 等）：那是 Termux 的 libc，
  混进去会满屏 `version 'LIBC' not found`。lgpu-run 默认只放 glibc 的目录，别手动
  把它污染了 —— 需要别的库用 `-L` 显式加。
- glibc 根默认 `$PREFIX/glibc`（`CCODROID_GLIBC_ROOT` 可覆盖）；解释器是
  `$PREFIX/glibc/lib/ld-linux-aarch64.so.1`。
- 默认 `TU_DEBUG=sysmem`（关 tiling，a7xx/a8xx 更稳）；要改用 `CCODROID_TU_DEBUG=`。

## OpenCL（clvk）

glibc 侧用不了厂商的 OpenCL（那是 bionic 库），要用 **clvk**（OpenCL over Vulkan → Turnip）。
clvk 由本仓库 CI 编译（clspv + LLVM + libclc 在手机上是小时级），产物放 Release：

```sh
./install-clvk.sh                    # 取 libOpenCL.so + clspv，核对 SHA256，装进 $PREFIX/glibc
./install-clvk.sh --dry-run          # 先看它要做什么
lgpu-cc lib/clprobe.c -o clprobe -lOpenCL && lgpu-run ./clprobe   # 自测：枚举 + 向量加 kernel
```

装好后 `$PREFIX/glibc/lib/libOpenCL.so` 即 OpenCL 实现（`-lOpenCL` 直接链得上），
`$PREFIX/glibc/bin/clspv` 可离线把 OpenCL C 编成 SPIR-V。clspv 也已内嵌在库里，
`clCreateProgramWithSource` 直接就能编译 kernel。

## 坑

- **`LD_PRELOAD` 必须摘掉**：cccodroid 的 shell 给每个进程挂了 bionic 的 termux-exec 垫片，
  glibc 的 ld.so 会跨 libc 继承它，然后按 glibc 的名字解析它的依赖 → 报
  `.../glibc/lib/libc.so: invalid ELF header`（看着像 glibc 装坏了，其实是这个垫片）。
  `lgpu-run` 会自动摘掉（要保留自己的预载用 `CCODROID_LGPU_PRELOAD`）；手写命令时记得 `env -u LD_PRELOAD`。
- **库路径里绝不能有 bionic 的目录**（`$PREFIX/lib` 等）：符号版本是 `LIBC`/`LIBC_N`，混进去会
  满屏 `version 'LIBC' not found`。
- **厂商的 `libOpenCL.so` 用不了**：那是 bionic 库，glibc 进程加载不了。glibc 侧要 OpenCL 只能走
  clvk（OpenCL over Vulkan，本仓库有 CI 构建）或 Mesa 的 rusticl。
- **zink 需要 glibc 版 Mesa**（组件不带，体积大且各发行版版本不一）：用你已有的
  （例如 blender-cli-android 解出来的 debroot/lfdevs Mesa），`lgpu-info` 会告诉你缺什么。
- 缺 `__EGL_VENDOR_LIBRARY_FILENAMES` 时 EGL 只会报误导性的 `EGL_BAD_PARAMETER`——
  `-z` 会自动找 `share/glvnd/egl_vendor.d/50_mesa.json`。
- Android 上没有 `/dev/dri/*`，所以 `EGL_PLATFORM=surfaceless`（`-z` 默认已设）；
  需要窗口的程序仍然跑不了（没有 X11/Wayland 服务端）。
- 只对高通 Adreno 有效（走 `/dev/kgsl-3d0`）。

## 需要用户同意

- 装/删 glibc Mesa、往 `$PREFIX/glibc` 外写东西：先问。lgpu-run 只往
  `~/.cccodroid/gpu-driver/` 写缓存与修补过的 ICD json。
