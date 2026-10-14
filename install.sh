#!/bin/bash
# install.sh — 手动安装（完整版：多一个可选的 HAL 通道和 gpu-switch）
#
#   ./install.sh [--dry-run] [--no-bin] [--fetch] [--hal-zip <zip路径或URL>]
#
#   --dry-run   只打印将要做的事，不动任何文件
#   --no-bin    不往 $PREFIX/bin 放 gpu-run/gpu-info/gpu-switch
#   --fetch     从上游下载 Turnip 的标准 ICD（Termux 官方仓库，校验 sha256）
#   --hal-zip   额外装 HAL 通道：AdrenoToolsDrivers 的 Turnip zip（按 GPU 代际选）
#               —— 载荷不随本仓库分发，用的时候现取；垫片由 src/ 现场编译
#
# 组件目录默认 $PREFIX/lib/gpu-driver（CCODROID_GPU_DIR 可覆盖，便于沙盒测试）。
#
# 大多数情况下不需要跑这个脚本：在 cccodroid 应用里装组件市场的 gpu-driver 更省事
# （同样的 gpu-run / gpu-info，只是不带 HAL 载荷和 gpu-switch）。
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${CCODROID_PREFIX:-${PREFIX:?PREFIX 未设置（本环境由 App 提供）}}"
GDIR="${CCODROID_GPU_DIR:-$PREFIX/lib/gpu-driver}"

DRY=0; NOBIN=0; FETCH=0; HALZIP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --no-bin) NOBIN=1; shift ;;
    --fetch) FETCH=1; shift ;;
    --hal-zip) HALZIP="${2:?--hal-zip 需要参数}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

run() { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }
step() { echo; echo "== $* =="; }

step "环境检查"
[ -c /dev/kgsl-3d0 ] || echo "警告：没有 /dev/kgsl-3d0（非高通设备？Turnip 需要它）"
command -v python3 >/dev/null || { echo "缺 python3" >&2; exit 1; }
command -v patchelf >/dev/null || { echo "缺 patchelf" >&2; exit 1; }
printf 'GPU: %s\n' "$(cat /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null || echo '(未知)')"
echo "组件目录: $GDIR"

step "建目录"
for d in icd hal/loader_shim vendor lib bin; do run mkdir -p "$GDIR/$d"; done

step "脚本与探针"
run cp -f "$HERE/lib/probe.py" "$GDIR/lib/probe.py"
run cp -f "$HERE/bin/gpu-run" "$HERE/bin/gpu-info" "$HERE/bin/gpu-switch" "$GDIR/bin/"
run chmod 755 "$GDIR/bin/gpu-run" "$GDIR/bin/gpu-info" "$GDIR/bin/gpu-switch"
if [ "$NOBIN" = 0 ]; then
  run ln -sf "$GDIR/bin/gpu-run" "$PREFIX/bin/gpu-run"
  run ln -sf "$GDIR/bin/gpu-info" "$PREFIX/bin/gpu-info"
  run ln -sf "$GDIR/bin/gpu-switch" "$PREFIX/bin/gpu-switch"
fi

step "Turnip（标准 ICD 通道）"
ICD_SO="$HERE/payload/icd/libvulkan_freedreno.so"
if [ ! -f "$ICD_SO" ] && [ ! -f "$GDIR/icd/libvulkan_freedreno.so" ]; then
  if [ "$FETCH" = 1 ]; then
    run python3 "$HERE/lib/fetch_turnip.py" "$HERE/payload"
  else
    echo "缺 $ICD_SO：加 --fetch 从 Termux 官方仓库下载" >&2
    exit 1
  fi
fi
run cp -f "$ICD_SO" "$GDIR/icd/libvulkan_freedreno.so"
run chmod 755 "$GDIR/icd/libvulkan_freedreno.so"
run patchelf --set-rpath "$PREFIX/lib" "$GDIR/icd/libvulkan_freedreno.so"
if [ "$DRY" = 0 ]; then
  python3 - "$GDIR" <<'PYEOF'
import json, os, sys
gdir = sys.argv[1]
p = os.path.join(gdir, "icd", "freedreno_icd.json")
json.dump({"file_format_version": "1.0.1",
           "ICD": {"api_version": "1.4.354",
                   "library_arch": "64",
                   "library_path": os.path.join(gdir, "icd", "libvulkan_freedreno.so")}},
          open(p, "w"), indent=2)
print("  写入", p)
PYEOF
fi

step "HAL 通道（可选）"
HAL_SO="$HERE/payload/hal/vulkan.adreno.so"
if [ -n "$HALZIP" ]; then
  run mkdir -p "$HERE/payload/hal"
  case "$HALZIP" in
    http*) run curl -sSL -o "$HERE/payload/hal/driver.zip" "$HALZIP" ;;
    *) run cp -f "$HALZIP" "$HERE/payload/hal/driver.zip" ;;
  esac
  if [ "$DRY" = 0 ]; then
    python3 - "$HERE/payload/hal" <<'PYEOF'
import os, sys, zipfile
d = sys.argv[1]
with zipfile.ZipFile(os.path.join(d, "driver.zip")) as z:
    for n in z.namelist():
        if n.endswith(".so"):
            open(os.path.join(d, "vulkan.adreno.so"), "wb").write(z.read(n))
            print("  ", n, "-> vulkan.adreno.so")
PYEOF
  fi
  HAL_SO="$HERE/payload/hal/vulkan.adreno.so"
fi
if [ -f "$HAL_SO" ] || [ -f "$GDIR/hal/vulkan.adreno.so" ]; then
  [ -f "$HAL_SO" ] && run cp -f "$HAL_SO" "$GDIR/hal/vulkan.adreno.so"
  run chmod 755 "$GDIR/hal/vulkan.adreno.so"
  run patchelf --set-soname vulkan.adreno.so "$GDIR/hal/vulkan.adreno.so"
  run cp -f /system/lib64/libvulkan.so "$GDIR/hal/loader_shim/libvulkan.so.1"
  # 垫片：仓库不带二进制，从源码现场编（约 40 行，只调 libgraphicsenv.so）
  if [ -f "$HERE/src/gpu_bootstrap.cpp" ] && command -v clang++ >/dev/null; then
    run clang++ -shared -fPIC -O2 -o "$GDIR/hal/gpu_bootstrap.so" "$HERE/src/gpu_bootstrap.cpp" -ldl
  fi
  echo "  HAL 通道已安装（用 gpu-run -m hal）"
else
  echo "  跳过（没有 HAL 载荷；可选：--hal-zip <AdrenoToolsDrivers 的 Turnip zip>）"
fi

step "厂商 OpenCL（拷进组件目录备用，不立即启用）"
run cp -f /vendor/lib64/libOpenCL.so "$GDIR/vendor/libOpenCL.so"
run chmod 755 "$GDIR/vendor/libOpenCL.so"

step "完成"
cat <<'EOT'
自检:      gpu-info
跑程序:    gpu-run <程序>            # Turnip（Vulkan 1.4）
           gpu-run -z <程序>         # zink（OpenGL/GLES on Vulkan）
           gpu-run --opencl <程序>   # 厂商 OpenCL（不动 $PREFIX 里任何文件）
           gpu-run -m hal <程序>     # 系统 loader + HAL 驱动（装了载荷才可用）
换成全局:  gpu-switch opencl on      # 直接换 $PREFIX/lib/libOpenCL.so（带备份）
EOT
