#!/usr/bin/env python3
"""
bundle_ffmpeg.py — 递归收集 ffmpeg 及其所有动态库依赖
用法: python3 bundle_ffmpeg.py <macos_dir>
"""

import subprocess
import shutil
import os
import sys


def collect_deps(macos_dir):
    """递归收集 ffmpeg 及其所有 Homebrew 动态库依赖"""
    deps_dir = os.path.join(macos_dir, "_dependencies")
    
    # 清理旧的依赖目录
    if os.path.exists(deps_dir):
        shutil.rmtree(deps_dir)
    os.makedirs(deps_dir, exist_ok=True)

    collected = set()

    def _collect(binary_path):
        if binary_path in collected:
            return
        collected.add(binary_path)

        if not os.path.exists(binary_path):
            print(f"  ⚠️  缺少依赖: {binary_path}")
            return

        try:
            result = subprocess.run(
                ["otool", "-L", binary_path],
                capture_output=True, text=True, timeout=10
            )
            for line in result.stdout.split('\n'):
                line = line.strip()
                if '/opt/homebrew' in line and '.dylib' in line:
                    lib_path = line.split('(')[0].strip()
                    if lib_path and os.path.exists(lib_path):
                        basename = os.path.basename(lib_path)
                        dest = os.path.join(deps_dir, basename)

                        if lib_path not in collected:
                            # 复制库文件（强制覆盖）
                            if os.path.exists(dest):
                                os.remove(dest)
                            shutil.copy2(lib_path, dest)
                            print(f"  打包: {basename}")

                            # 修改 install_name 为自包含路径
                            try:
                                subprocess.run(
                                    ["install_name_tool", "-id",
                                     f"@executable_path/_dependencies/{basename}",
                                     dest],
                                    capture_output=True, timeout=10,
                                    check=True
                                )
                            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                                pass

                            # 递归收集该库的依赖
                            _collect(lib_path)
        except Exception as e:
            print(f"  处理 {binary_path} 时出错: {e}")

    _collect(os.path.join(macos_dir, "ffmpeg"))
    _collect(os.path.join(macos_dir, "ffprobe"))

    # 修改 ffmpeg 和 ffprobe 的 install_name 引用
    libs_to_fix = set()
    for lib_path in collected:
        basename = os.path.basename(lib_path)
        dest = os.path.join(deps_dir, basename)
        if os.path.exists(dest):
            libs_to_fix.add((lib_path, basename))

    for lib_path, basename in libs_to_fix:
        new_id = f"@executable_path/_dependencies/{basename}"
        try:
            subprocess.run(
                ["install_name_tool", "-change", lib_path, new_id,
                 os.path.join(macos_dir, "ffmpeg")],
                capture_output=True, timeout=10
            )
            subprocess.run(
                ["install_name_tool", "-change", lib_path, new_id,
                 os.path.join(macos_dir, "ffprobe")],
                capture_output=True, timeout=10
            )
        except subprocess.TimeoutExpired:
            pass
        except Exception:
            pass

    print(f"\n  ✅ 共打包 {len(collected)} 个动态库依赖")
    return len(collected)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("用法: python3 bundle_ffmpeg.py <macos_dir>")
        sys.exit(1)
    macos_dir = sys.argv[1]
    if not os.path.isdir(macos_dir):
        print(f"错误: {macos_dir} 不是有效目录")
        sys.exit(1)
    collect_deps(macos_dir)
