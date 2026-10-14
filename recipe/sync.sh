#!/bin/bash
# sync.sh — 把本仓库的脚本同步进 cccodroid-components 的配方目录
#
#   ./sync.sh <cccodroid-components 仓库路径>
#
# 脚本只有一个来源（本仓库的 bin/ lib/ skill/ glibc/），配方目录里的副本由它生成；
# 改完脚本跑一次，别两边各改一份。
#
# 注：glibc 配方（gpu-driver-glibc，kind=glibc）默认也同步过去，但市场 v1 还不放行
# kind=glibc（见 cccodroid 主仓库 devkit.mjs 的白名单），等那边的 PR 合了再发布。
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MARKET="${1:?用法: ./sync.sh <cccodroid-components 仓库路径>}"

echo "同步到 $MARKET"

# ── bionic 侧：gpu-run / gpu-info / probe.py（不带 gpu-switch：它不随市场分发）──
D="$MARKET/recipes/gpu-driver"
if [ -d "$D" ]; then
  mkdir -p "$D/bin" "$D/lib" "$D/skill"
  cp -f "$REPO/bin/gpu-run" "$REPO/bin/gpu-info" "$D/bin/"
  cp -f "$REPO/lib/probe.py" "$D/lib/"
  cp -f "$REPO/skill/SKILL.md" "$D/skill/SKILL.md"
  cp -f "$REPO/recipe/recipe.json" "$D/recipe.json"
  echo "  同步 gpu-driver"
else
  echo "  跳过 gpu-driver（$D 不存在；先在市场仓库建好配方目录）"
fi

# ── glibc 侧 ──
D="$MARKET/recipes/gpu-driver-glibc"
if [ -d "$D" ]; then
  mkdir -p "$D/bin" "$D/lib" "$D/skill"
  cp -f "$REPO/glibc/bin/"* "$D/bin/"
  cp -f "$REPO/glibc/lib/"*.py "$D/lib/"
  cp -f "$REPO/glibc/skill/SKILL.md" "$D/skill/SKILL.md"
  cp -f "$REPO/glibc/recipe.json" "$D/recipe.json"
  echo "  同步 gpu-driver-glibc"
else
  echo "  跳过 gpu-driver-glibc（$D 不存在）"
fi
echo "完成"
