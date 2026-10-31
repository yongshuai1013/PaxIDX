#!/usr/bin/env python3
# 把 BeeWare Python.xcframework 轉成「App 內嵌布局」：
#   <out>/Frameworks/<模組>.framework/…（lib-dynload 的 .so 逐個轉 framework）
#   <out>/python/lib/python3.13/…（合併標準庫，lib-dynload 原位留 .fwork 佔位）
# 布局與 BeeWare 官方 install_python 一致（CPyTest 與 PaxIDX 打包器已驗證）。
# 用法：make_python_embed.py <Python.xcframework 路徑> <輸出目錄>
import os
import plistlib
import shutil
import sys

BUNDLE_PREFIX = "com.yongshuai.paxidx.py."
PYTHON_VER = "python3.13"


def main() -> int:
    xcf, out = sys.argv[1], sys.argv[2]
    lib_dst = os.path.join(out, "python", "lib", PYTHON_VER)
    os.makedirs(lib_dst, exist_ok=True)
    # 合併標準庫：通用 lib/ 為底，裝置 slice 的 lib-arm64 疊上去（含 lib-dynload）
    shutil.copytree(os.path.join(xcf, "lib", PYTHON_VER), lib_dst, dirs_exist_ok=True)
    shutil.copytree(os.path.join(xcf, "ios-arm64", "lib-arm64", PYTHON_VER),
                    lib_dst, dirs_exist_ok=True)

    with open(os.path.join(xcf, "build", "iOS-dylib-Info-template.plist"), "rb") as f:
        template = plistlib.load(f)

    dyn_dir = os.path.join(lib_dst, "lib-dynload")
    fw_root = os.path.join(out, "Frameworks")
    os.makedirs(fw_root, exist_ok=True)
    count = 0
    for name in sorted(os.listdir(dyn_dir)):
        if not name.endswith(".so"):
            continue
        module = name.split(".")[0]
        fw_dir = os.path.join(fw_root, module + ".framework")
        os.makedirs(fw_dir, exist_ok=True)
        info = dict(template)
        info["CFBundleExecutable"] = module
        info["CFBundleIdentifier"] = (BUNDLE_PREFIX + module).replace("_", "-")
        with open(os.path.join(fw_dir, "Info.plist"), "wb") as f:
            plistlib.dump(info, f)
        shutil.move(os.path.join(dyn_dir, name), os.path.join(fw_dir, module))
        os.chmod(os.path.join(fw_dir, module), 0o755)
        base = name[: -len(".so")]
        with open(os.path.join(dyn_dir, base + ".fwork"), "w") as f:
            f.write(f"Frameworks/{module}.framework/{module}\n")
        with open(os.path.join(fw_dir, module + ".origin"), "w") as f:
            f.write(f"python/lib/{PYTHON_VER}/lib-dynload/{base}.fwork\n")
        count += 1
    print(f"make_python_embed: {count} 個擴展模組 framework 化完成 -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
