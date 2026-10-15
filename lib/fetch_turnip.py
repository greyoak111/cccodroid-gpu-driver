#!/usr/bin/env python3
"""下载 Termux 官方 mesa-vulkan-icd-freedreno（标准 ICD 形式的 Turnip）。

用法: fetch_turnip.py [目标目录]      # 默认 payload/
产物: <目标目录>/icd/libvulkan_freedreno.so
（rpath 由 install.sh 用 patchelf 设置；直接用时记得：patchelf --set-rpath $PREFIX/lib）
"""
import io
import os
import re
import subprocess
import sys
import tarfile

PKG = "pool/main/m/mesa-vulkan-icd-freedreno/"
BASES = [
    "https://packages-cf.termux.dev/apt/termux-main/",
    "https://packages.termux.dev/apt/termux-main/",
    "https://mirrors.utermux.dev/termux/apt/termux-main/",
]


def fetch(url, timeout=120):
    # 别加 -k：这里拉的是要装进进程里的驱动库，而且没有别的校验，全靠 TLS。
    # 某个镜像证书有问题时它会失败（CalledProcessError），main() 里自然换下一个镜像
    out = subprocess.run(["curl", "-fsSL", "--max-time", str(timeout), url],
                         capture_output=True, check=True)
    return out.stdout


def main():
    target = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "payload")
    icd_dir = os.path.join(target, "icd")
    os.makedirs(icd_dir, exist_ok=True)

    data, name = None, None
    for base in BASES:
        try:
            html = fetch(base + PKG, timeout=30).decode("utf-8", "replace")
        except subprocess.CalledProcessError as e:
            print("清单拉取失败:", base, e)
            continue
        names = [n for n in sorted(set(re.findall(r'href="([^"]+\.deb)"', html)))
                 if "aarch64" in n]
        if names:
            print("镜像:", base, "版本:", names[-1])
            name = names[-1]
            data = fetch(base + PKG + name)
            break
        print("镜像无包:", base)
    if data is None:
        print("所有镜像都失败", file=sys.stderr)
        return 1
    print("下载:", name, len(data), "bytes")

    assert data[:8] == b"!<arch>\n", "不是 ar 归档"
    off, members = 8, {}
    while off + 60 <= len(data):
        hdr = data[off:off + 60]
        mname = hdr[:16].decode().strip().rstrip("/")
        try:
            size = int(hdr[48:58].decode().strip())
        except ValueError:
            break
        off += 60
        members[mname] = data[off:off + size]
        off += size + (size % 2)

    raw = None
    for m, blob in members.items():
        if not m.startswith("data.tar"):
            continue
        if m.endswith(".xz"):
            import lzma
            raw = lzma.decompress(blob)
        elif m.endswith(".gz"):
            import gzip
            raw = gzip.decompress(blob)
        elif m.endswith(".zst"):
            try:
                from compression import zstd  # py3.14+
                raw = zstd.decompress(blob)
            except ImportError:
                import zstandard
                raw = zstandard.ZstdDecompressor().decompress(blob)
        elif m.endswith(".tar"):
            raw = blob
    if raw is None:
        print("data.tar 缺失", file=sys.stderr)
        return 1

    tf = tarfile.open(fileobj=io.BytesIO(raw))
    want = None
    for member in tf.getmembers():
        if member.name.endswith("libvulkan_freedreno.so"):
            want = member
            break
    if want is None:
        print("包内没有 libvulkan_freedreno.so", file=sys.stderr)
        return 1
    src = tf.extractfile(want)
    dst_path = os.path.join(icd_dir, "libvulkan_freedreno.so")
    with open(dst_path, "wb") as f:
        f.write(src.read())
    os.chmod(dst_path, 0o755)
    print("写入:", dst_path, os.path.getsize(dst_path), "bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
