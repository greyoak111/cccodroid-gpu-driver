# ci/

**`build-clvk.yml` 应该放在 `.github/workflows/build-clvk.yml`**，但推它需要 gh token 带
`workflow` scope（GitHub 不让 OAuth App 直接创建/修改工作流文件）：

```sh
gh auth refresh -s workflow      # 按提示走一次浏览器
cp ci/build-clvk.yml .github/workflows/build-clvk.yml
git add .github/workflows/build-clvk.yml && git commit -m 'ci: clvk 构建' && git push
```

或者直接在 GitHub 网页上新建 `.github/workflows/build-clvk.yml`，把这份粘进去。
搬过去之后这个目录就可以删了。

工作流做的事：在 `ubuntu-24.04-arm` 上按上游（clvk 的 presubmit.yml + Termux 的 clvk/build.sh）
编 clvk —— 取 clvk 源码 + LLVM 源码，编 libclc，再以在线编译器模式把 clspv 内嵌进
`libOpenCL.so`。产物 `libOpenCL.so` + `clspv` + `SHA256SUMS` 传成 artifact，打 tag 时发 Release。

为什么不在设备上编：clspv 要整套 LLVM + clang 前端 + libclc，8 核手机上小时级，
中途切后台/没电就前功尽弃。
