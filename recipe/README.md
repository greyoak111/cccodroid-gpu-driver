# recipe/

cccodroid 组件市场的配方（[格式说明](https://github.com/greyoak111/cccodroid-components/blob/main/docs/recipe.md)）。

配方目录里那份 `bin/gpu-run`、`bin/gpu-info`、`lib/probe.py`、`skill/SKILL.md`
是**本仓库同名文件的副本**，由 `sync.sh` 生成 —— 改脚本请改本仓库的，再同步：

```sh
./sync.sh <cccodroid-components 仓库的本地路径>
```

市场版与手动版的差别：市场版不带 HAL 载荷、不带 `gpu-switch`（那两个会碰 `$PREFIX` 里的文件或多带二进制）。
