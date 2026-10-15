#!/bin/bash
# install-clvk.sh — 装上 clvk（OpenCL over Vulkan）的 glibc 版
#
#   ./install-clvk.sh [--dry-run] [--version clvk-2026.10.15] [--from <本地目录>]
#
#   clvk 由本仓库的 CI 构建（.github/workflows/build-clvk.yml），不含在这里：
#     产物 libOpenCL.so（自包含：clspv + libclc 都在里面）+ clspv 命令行 + SHA256SUMS
#   默认取最新的 clvk-* Release；下载后**核对 Release 里的 SHA256SUMS**，再装到：
#     $PREFIX/glibc/lib/libOpenCL.so（+ .so.1 软链）
#     $PREFIX/glibc/bin/clspv
#     $PREFIX/glibc/etc/OpenCL/vendors/clvk.icd
#
#   为什么 glibc 侧的 OpenCL 只能用 clvk：厂商的 libOpenCL.so 是 bionic 库，
#   glibc 进程加载不了（跨 libc）。
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="greyoak111/cccodroid-gpu-driver-snapdragon"
PREFIX="${CCODROID_PREFIX:-${PREFIX:-}}"
[ -n "$PREFIX" ] || { echo "PREFIX 未设置（本环境由 App 提供）" >&2; exit 1; }
GROOT="${CCODROID_GLIBC_ROOT:-$PREFIX/glibc}"

DRY=0; VER=""; FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --version) VER="${2:?--version 需要参数}"; shift 2 ;;
    --from) FROM="${2:?--from 需要参数}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done
run() { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }

WORK="$(mktemp -d "$PREFIX/tmp/clvk.XXXXXX" 2>/dev/null || mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -n "$FROM" ]; then
  cp -f "$FROM"/libOpenCL.so "$FROM"/clspv "$FROM"/SHA256SUMS "$WORK/" 2>/dev/null || true
else
  [ -n "$VER" ] || VER="$(gh release list -R "$REPO" --limit 30 --json tagName \
      --jq '[.[].tagName | select(startswith("clvk-"))] | first // ""' 2>/dev/null)"
  [ -n "$VER" ] || { echo "拿不到 Release 版本（没网？没有 Release？）" >&2; exit 1; }
  echo "版本：$VER"
  for f in libOpenCL.so clspv SHA256SUMS; do
    run gh release download "$VER" -R "$REPO" -p "$f" -D "$WORK" --clobber
  done
fi

# 核对 Release 自带的 SHA256SUMS（两份 sha256sum 输出格式一致）
if [ "$DRY" = 0 ]; then
  (cd "$WORK" && grep -E 'libOpenCL\.so|clspv' SHA256SUMS > want.txt && sha256sum -c want.txt)
fi

run mkdir -p "$GROOT/lib" "$GROOT/bin" "$GROOT/etc/OpenCL/vendors"
run install -m 755 "$WORK/libOpenCL.so" "$GROOT/lib/libOpenCL.so"
run ln -sf libOpenCL.so "$GROOT/lib/libOpenCL.so.1"
run install -m 755 "$WORK/clspv" "$GROOT/bin/clspv"
if [ "$DRY" = 0 ]; then
  printf '%s\n' "$GROOT/lib/libOpenCL.so" > "$GROOT/etc/OpenCL/vendors/clvk.icd"
fi

echo "装好了："
echo "  $GROOT/lib/libOpenCL.so   （链 -lOpenCL 的 glibc 程序直接可用）"
echo "  $GROOT/bin/clspv          （离线编译 kernel 用）"
echo
echo "自检："
echo "  lgpu-run $GROOT/bin/clinfo            # 若有 clinfo"
echo "  lgpu-run python3 -c \"import ctypes; ctypes.CDLL('libOpenCL.so')\""
