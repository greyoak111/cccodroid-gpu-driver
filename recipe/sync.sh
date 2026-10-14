#!/bin/bash
# sync.sh — 把本仓库的脚本同步进 cccodroid-components 的配方目录
#
#   ./sync.sh <cccodroid-components 仓库路径>
#
# 脚本只有一个来源（本仓库的 bin/ lib/ skill/），配方目录里的副本由它生成；
# 改完脚本跑一次，别两边各改一份。
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DEST="${1:?用法: ./sync.sh <cccodroid-components 仓库路径>}/recipes/gpu-driver"

[ -d "$DEST" ] || { echo "找不到 $DEST" >&2; exit 1; }
mkdir -p "$DEST/bin" "$DEST/lib" "$DEST/skill"
cp -f "$REPO/bin/gpu-run" "$REPO/bin/gpu-info" "$DEST/bin/"
cp -f "$REPO/lib/probe.py" "$DEST/lib/"
cp -f "$REPO/skill/SKILL.md" "$DEST/skill/"
cp -f "$HERE/recipe.json" "$DEST/recipe.json"
echo "已同步到 $DEST"
