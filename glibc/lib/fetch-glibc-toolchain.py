#!/usr/bin/env python3
"""补齐「用本机 clang 编 glibc 程序」缺的那几块料（cccodroid gpu-driver-glibc 组件）。

要什么：链接一个 aarch64-linux-gnu（glibc）程序，除了 glibc 自己的 crt1.o/crti.o/crtn.o
和 libc.so 链接脚本，还需要 GCC 运行时的那几件：
  crtbegin.o crtbeginS.o crtbeginT.o crtend.o crtendS.o crtfastmath.o libgcc.a libgcc_eh.a
  libgcc_s.so/.so.1（共享）
这些在 Termux 官方 glibc 仓库的 gcc-glibc / gcc-libs-glibc 包里（就是常说的 libgcc-14-dev 的内容）。
整包 84MB，我们只要里面几百 KB，所以：下 .deb → 核对索引里的 SHA256 → 只挑这几个文件出来。

用法: fetch-glibc-toolchain.py [目标目录]        # 默认 ~/.cccodroid/gpu-driver/toolchain
产物: <目标>/gcc/<gcc 版本>/…   <目标>/lib/…
"""
import gzip
import io
import lzma
import os
import re
import subprocess
import sys
import tarfile
import urllib.parse

BASES = [
    "https://packages-cf.termux.dev/apt/termux-glibc/",
    "https://packages.termux.dev/apt/termux-glibc/",
]
DIST = "dists/glibc/stable/binary-aarch64"
WANT_PKGS = ["gcc-glibc", "gcc-libs-glibc"]
# 要挑出来的文件（包里的 basename，精确匹配）。libstdc++ 不在这里
# —— 它由 glibc 组件的 gcc-libs-glibc 提供，已经在 $PREFIX/glibc/lib 里了。
WANT_FILES = {"crtbegin.o", "crtbeginS.o", "crtbeginT.o", "crtend.o", "crtendS.o",
              "crtfastmath.o", "libgcc.a", "libgcc_eh.a", "libgcc_s.so", "libgcc_s.so.1"}


def curl(url, timeout=600):
    # 别加 -k：索引（Packages.gz）也是从这条连接取的，证书不校验，下面「核对 SHA256」就形同虚设
    out = subprocess.run(["curl", "-fsSL", "--max-time", str(timeout), url],
                         capture_output=True, check=True)
    return out.stdout


def index_of(base):
    """取 Packages.gz，返回 {包名: 该包的字段 dict}（同类取版本号最大的那条）。"""
    raw = gzip.decompress(curl(base + DIST + "/Packages.gz", 300)).decode("utf-8", "replace")
    pkgs = {}
    for block in raw.split("\n\n"):
        if not block.strip():
            continue
        fields = {}
        last = None
        for line in block.split("\n"):
            m = re.match(r"^([A-Za-z0-9-]+):\s?(.*)$", line)
            if m:
                last = m[1]
                fields[last] = m[2]
            elif last and line.startswith(" "):
                fields[last] += "\n" + line.strip()
        name = fields.get("Package")
        if not name:
            continue
        cur = pkgs.get(name)
        if cur is None or _ver_key(fields.get("Version", "")) > _ver_key(cur.get("Version", "")):
            pkgs[name] = fields
    return pkgs


def _ver_key(v):
    return [int(x) if x.isdigit() else x for x in re.split(r"[.\-~]", v)]


def extract_deb(deb, dest_root):
    """从 .deb 里挑出 WANT_FILES，写到 dest_root 下（保持尽量精简的层级）。返回写入的文件数。"""
    assert deb[:8] == b"!<arch>\n", "不是 ar 归档"
    off, members = 8, {}
    while off + 60 <= len(deb):
        hdr = deb[off:off + 60]
        mname = hdr[:16].decode().strip().rstrip("/")
        try:
            size = int(hdr[48:58].decode().strip())
        except ValueError:
            break
        off += 60
        members[mname] = deb[off:off + size]
        off += size + (size % 2)

    raw = None
    for m, blob in members.items():
        if m.startswith("data.tar"):
            if m.endswith(".xz"):
                raw = lzma.decompress(blob)
            elif m.endswith(".gz"):
                raw = gzip.decompress(blob)
            elif m.endswith(".tar"):
                raw = blob
            elif m.endswith(".zst"):
                try:
                    from compression import zstd
                except ImportError:
                    import zstandard
                    zstd = zstandard.ZstdDecompressor()
                raw = zstd.decompress(blob)
    if raw is None:
        raise SystemExit("data.tar 缺失")

    n = 0
    tf = tarfile.open(fileobj=io.BytesIO(raw))
    for member in tf.getmembers():
        base = os.path.basename(member.name)
        if not member.isfile() or base not in WANT_FILES:
            continue
        # 路径：…/usr/glibc/lib/gcc/<triple>/<ver>/x → gcc/<ver>/x
        #       …/usr/glibc/lib/x                    → lib/x
        parts = member.name.split("/")
        if "gcc" in parts:
            i = parts.index("gcc")
            rel = os.path.join(*parts[i:])
        else:
            rel = os.path.join("lib", base)
        dst = os.path.join(dest_root, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as f:
            f.write(tf.extractfile(member).read())
        os.chmod(dst, 0o755 if base.endswith(".so") or base.endswith(".so.1") else 0o644)
        n += 1
    return n


def main():
    dest = os.path.abspath(sys.argv[1] if len(sys.argv) > 1
                           else os.path.expanduser("~/.cccodroid/gpu-driver/toolchain"))
    os.makedirs(dest, exist_ok=True)

    for base in BASES:
        try:
            idx = index_of(base)
        except Exception as e:                                  # noqa: BLE001
            print("索引拉取失败:", base, e)
            continue
        print("镜像:", base)
        for name in WANT_PKGS:
            p = idx.get(name)
            if not p:
                print("  索引里没有", name)
                continue
            url = urllib.parse.urljoin(base, p["Filename"])
            print(f"  {name} {p['Version']} ← {p['Filename']}")
            deb = curl(url)
            import hashlib
            got = hashlib.sha256(deb).hexdigest()
            if got != p.get("SHA256"):
                print(f"  ✗ SHA256 不符：索引 {p.get('SHA256')} / 实得 {got}", file=sys.stderr)
                return 1
            n = extract_deb(deb, dest)
            print(f"    ✓ sha256 校验通过，挑出 {n} 个文件")
        break
    else:
        print("所有镜像都失败", file=sys.stderr)
        return 1

    print("工具链碎片在:", dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
