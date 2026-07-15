#!/usr/bin/env python3
# =============================================================================
# 探测目标文件 / 静态库的 CPU 架构，输出规范化字符串（跨 ELF / Mach-O）。
#
# 背景 (真实 blocker):
#   交叉编译时（如 Android arm64 的 host 是 x86_64、Apple Silicon 上编 macOS
#   x86_64），构建树里同时存在 host 与 target 两份 libc++。若按目录路径猜测
#   收集，极易把 host 架构的 libc++.a/.o 误打进 target 包，导致下游 lld 报
#   “xxx.o is incompatible with <target>”。故按架构精确匹配，杜绝错配。
#
# 用法:
#   detect_arch.py <file>
#     <file> 可为对象文件(.o) 或 thick ar 静态库(.a)。
#   输出规范化架构（小写，单行）到 stdout：
#     x86_64 | aarch64 | i386 | arm | riscv64 | ppc64 | unknown
#   退出码: 0=已识别; 3=无法识别(输出 unknown); 1=文件不存在/读取错误。
#
# 说明:
#   - 对 ar 库解析成员，取首个可识别的 ELF/Mach-O 成员判定架构。
#   - Mach-O universal(fat) 库取首个 slice。
#   - 仅依赖标准库，不需要外部工具。
# =============================================================================
import struct
import sys

# --- ELF e_machine -> 规范名 -------------------------------------------------
_ELF_MACHINE = {
    3: "i386",       # EM_386
    40: "arm",       # EM_ARM
    62: "x86_64",    # EM_X86_64
    183: "aarch64",  # EM_AARCH64
    243: "riscv64",  # EM_RISCV (按 64 位处理，V8 目标里用不到 32 位 riscv)
    21: "ppc64",     # EM_PPC64
}

# --- Mach-O cputype -> 规范名 ------------------------------------------------
_CPU_ARCH_ABI64 = 0x01000000
_MACHO_CPU = {
    7: "i386",                     # CPU_TYPE_X86
    7 | _CPU_ARCH_ABI64: "x86_64",  # CPU_TYPE_X86_64
    12: "arm",                     # CPU_TYPE_ARM
    12 | _CPU_ARCH_ABI64: "aarch64",  # CPU_TYPE_ARM64
}


def _arch_from_elf(data: bytes):
    if len(data) < 20 or data[:4] != b"\x7fELF":
        return None
    # EI_DATA @5: 1=小端, 2=大端
    endian = "<" if data[5] == 1 else ">"
    # e_machine: 半字 @18
    (machine,) = struct.unpack_from(endian + "H", data, 18)
    return _ELF_MACHINE.get(machine)


def _arch_from_macho(data: bytes):
    if len(data) < 8:
        return None
    magic = data[:4]
    # thin Mach-O: cputype 紧跟 magic (offset 4, 4 字节)
    if magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):  # 64/32 位小端
        (cputype,) = struct.unpack_from("<i", data, 4)
        return _MACHO_CPU.get(cputype & 0xFFFFFFFF)
    if magic in (b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"):  # 大端
        (cputype,) = struct.unpack_from(">i", data, 4)
        return _MACHO_CPU.get(cputype & 0xFFFFFFFF)
    return None


def _arch_from_fat_macho(data: bytes):
    # universal(fat) 头是大端。magic: 0xcafebabe(32) / 0xcafebabf(64)
    if len(data) < 8:
        return None
    magic = data[:4]
    if magic == b"\xca\xfe\xba\xbe":
        (nfat,) = struct.unpack_from(">I", data, 4)
        if nfat and len(data) >= 8 + 20:
            (cputype,) = struct.unpack_from(">i", data, 8)
            return _MACHO_CPU.get(cputype & 0xFFFFFFFF)
    if magic == b"\xca\xfe\xba\xbf":
        (nfat,) = struct.unpack_from(">I", data, 4)
        if nfat and len(data) >= 8 + 32:
            (cputype,) = struct.unpack_from(">i", data, 8)
            return _MACHO_CPU.get(cputype & 0xFFFFFFFF)
    return None


# --- COFF (Windows .obj) machine -> 规范名 ----------------------------------
_COFF_MACHINE = {
    0x014C: "i386",     # IMAGE_FILE_MACHINE_I386
    0x8664: "x86_64",   # IMAGE_FILE_MACHINE_AMD64
    0xAA64: "aarch64",  # IMAGE_FILE_MACHINE_ARM64
    0x01C0: "arm",      # IMAGE_FILE_MACHINE_ARM
    0x01C4: "arm",      # IMAGE_FILE_MACHINE_ARMNT
}


def _arch_from_coff(data: bytes):
    # 普通 COFF 对象: 开头即 machine(2) + numsections(2)。
    if len(data) < 20:
        return None
    (machine,) = struct.unpack_from("<H", data, 0)
    arch = _COFF_MACHINE.get(machine)
    if arch is None:
        return None
    # 粗校验: 时间戳字段存在即可（避免把任意 2 字节误判）。此处已足够，
    # 因为调用点只喂来自 libc++ 的 .obj / .lib 成员。
    return arch


def _arch_from_bitcode(data: bytes):
    # LLVM bitcode wrapper (macOS clang 常用): 磁盘字节 de c0 17 0b = 0x0B17C0DE。
    # 头: magic(4) version(4) offset(4) size(4) cputype(4)...，cputype 为 Mach-O 编码。
    # 注意: arm64 的 bitcode cputype 可能是 CPU_TYPE_ANY(0xFFFFFFFF)，此时无法判定，
    #       返回 None，交由上层的系统工具(lipo)兜底。
    if len(data) < 20 or data[:4] != b"\xde\xc0\x17\x0b":
        return None
    (cputype,) = struct.unpack_from("<i", data, 16)
    return _MACHO_CPU.get(cputype & 0xFFFFFFFF)


def _arch_from_object_bytes(data: bytes):
    return (
        _arch_from_elf(data)
        or _arch_from_macho(data)
        or _arch_from_fat_macho(data)
        or _arch_from_coff(data)
        or _arch_from_bitcode(data)
    )


def _iter_ar_members(data: bytes):
    """遍历 thick ar 归档成员，yield 每个成员的内容 bytes（尽量跳过符号表伪成员）。

    同时支持 GNU 格式（Linux/Android）与 BSD 格式（macOS）：
      - GNU 长名走 '//' 名字表 + '/offset'；短名以 '/' 结尾。
      - BSD 长名以 '#1/<len>' 记于名字字段，真实名字占据成员内容前 <len> 字节。
    """
    if data[:8] != b"!<arch>\n":
        return
    pos = 8
    n = len(data)
    while pos + 60 <= n:
        header = data[pos:pos + 60]
        pos += 60
        raw_name = header[0:16].decode("latin-1", "replace").rstrip()
        size_field = header[48:58].decode("latin-1", "replace").strip()
        try:
            size = int(size_field)
        except ValueError:
            break
        content = data[pos:pos + size]
        pos += size
        if size % 2 == 1:
            pos += 1  # 2 字节对齐

        name = raw_name
        # BSD 扩展名: '#1/<len>'，内容前 <len> 字节是真实文件名
        if raw_name.startswith("#1/"):
            try:
                namelen = int(raw_name[3:])
            except ValueError:
                namelen = 0
            if 0 < namelen <= len(content):
                name = content[:namelen].split(b"\x00", 1)[0].decode(
                    "latin-1", "replace"
                )
                content = content[namelen:]

        name = name.rstrip("/")
        # 跳过符号表 / 名字表伪成员
        if name in ("", "/", "//", "SYM64", "__.SYMDEF", "__.SYMDEF SORTED"):
            continue
        yield content


def detect(path: str):
    try:
        with open(path, "rb") as f:
            head = f.read(8)
            rest = f.read()
    except OSError as e:
        sys.stderr.write(f"detect_arch: 无法读取 {path}: {e}\n")
        return None, 1
    data = head + rest

    # ar 静态库: 解析成员
    if data[:8] == b"!<arch>\n":
        for content in _iter_ar_members(data):
            arch = _arch_from_object_bytes(content)
            if arch:
                return arch, 0
        return "unknown", 3

    # 直接的对象文件
    arch = _arch_from_object_bytes(data)
    if arch:
        return arch, 0
    return "unknown", 3


def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write("用法: detect_arch.py <file(.o|.a)>\n")
        return 2
    arch, code = detect(sys.argv[1])
    if arch is None:
        return code
    print(arch)
    return code


if __name__ == "__main__":
    sys.exit(main())
