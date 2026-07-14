#!/usr/bin/env python3
# =============================================================================
# 关闭 Chromium/V8 构建里的 thin archive（让 .a/.lib 直接产出 thick 归档）。
#
# 背景 (真实 blocker):
#   Chromium 默认给几乎所有静态库套上 //build/config/compiler:thin_archive，
#   给 arflags 加 -T（posix 生成 !<thin> 归档 / windows 加 /llvmlibthin）。
#   thin 归档只引用 .o 路径，拷进 zip/tar 后成员丢失，整包不可用。
#   之前脚本靠 llvm-ar 把 thin 转 thick，跨平台/跨 ar 版本极不稳定，几乎所有
#   平台都在 “转换 thin -> thick” 处失败。
#
#   Chromium 官方在该 config 的注释里明确写：要做可分发静态库就得
#   “移除 thin_archive config”，本脚本正是这么做——把 config 体清空，
#   V8 于是直接产出 thick libc++.a / 各中间静态库，collect 脚本只需拷贝。
#
# 用法:
#   disable_thin_archive.py <v8_src_root>
#
# 修改文件: <v8_src_root>/build/config/compiler/BUILD.gn
# 幂等: 已清空则跳过。找不到文件/config 则以非零退出（尽早暴露问题）。
# =============================================================================
import sys
from pathlib import Path

# Windows 上 Python stdout/stderr 默认可能是 cp1252，打印中文会 UnicodeEncodeError。
# 强制 UTF-8（errors=replace 兜底），保证脚本在任何 code page 下都不因日志编码而崩。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

MARKER = "# thin archive disabled by static-lib-builder"


def find_config_span(text: str, name: str):
    """返回 config("<name>") 从 'config' 关键字到匹配右花括号（含）的 [start, end)."""
    needle = f'config("{name}")'
    idx = text.find(needle)
    if idx < 0:
        return None
    brace = text.find("{", idx)
    if brace < 0:
        return None
    depth = 0
    i = brace
    while i < len(text):
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return (idx, i + 1)
        i += 1
    return None


def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write("用法: disable_thin_archive.py <v8_src_root>\n")
        return 2

    v8_src = Path(sys.argv[1])
    gn = v8_src / "build" / "config" / "compiler" / "BUILD.gn"
    if not gn.is_file():
        sys.stderr.write(f"错误: 未找到 {gn}\n")
        return 1

    text = gn.read_text(encoding="utf-8")

    if MARKER in text:
        print(f"==> thin_archive 已被清空，跳过: {gn}")
        return 0

    span = find_config_span(text, "thin_archive")
    if span is None:
        sys.stderr.write(
            f"错误: 在 {gn} 未找到 config(\"thin_archive\")（V8 目录结构可能变化）\n"
        )
        return 1

    start, end = span
    replacement = (
        'config("thin_archive") {\n'
        f"  {MARKER}\n"
        "  # 清空 arflags：不再产出 thin 归档，静态库直接包含 .o，可分发。\n"
        "}"
    )
    new_text = text[:start] + replacement + text[end:]
    gn.write_text(new_text, encoding="utf-8")
    print(f"==> 已清空 config(\"thin_archive\")，V8 将产出 thick 归档: {gn}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
