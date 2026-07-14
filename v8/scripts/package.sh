#!/usr/bin/env bash
# =============================================================================
# V8 打包脚本 (Unix: macOS / Linux / Android)
#
# 将 v8/out/<target>/{include,lib,libcxx,libcxxabi} 连同许可证与构建信息
# 打包为 tar.gz。复用 scripts/common.sh 的打包骨架。
#
# 用法:
#   v8/scripts/package.sh <target>
#
# 产物: v8/dist/<PACKAGE_NAME>-<version>-<target>.tar.gz
# =============================================================================
set -euo pipefail

TARGET="${1:?用法: package.sh <target>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${LIB_ROOT}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/common.sh"

# 所有配置以 config.env 为唯一来源。
load_env "${LIB_ROOT}/config.env"

case "${TARGET}" in
  macos-*)
    ENABLE_POINTER_COMPRESSION="${V8_ENABLE_POINTER_COMPRESSION_MACOS:?config.env 缺少 V8_ENABLE_POINTER_COMPRESSION_MACOS}"
    ;;
  linux-*)
    ENABLE_POINTER_COMPRESSION="${V8_ENABLE_POINTER_COMPRESSION_LINUX:?config.env 缺少 V8_ENABLE_POINTER_COMPRESSION_LINUX}"
    ;;
  android-*)
    ENABLE_POINTER_COMPRESSION="${V8_ENABLE_POINTER_COMPRESSION_ANDROID:?config.env 缺少 V8_ENABLE_POINTER_COMPRESSION_ANDROID}"
    ;;
  *) die "package.sh 不支持的 target: ${TARGET}" ;;
esac

case "${ENABLE_POINTER_COMPRESSION}" in
  true|false) ;;
  *) die "不支持的指针压缩配置: ${ENABLE_POINTER_COMPRESSION} (可选: true, false)" ;;
esac

VERSION="${PACKAGE_VERSION:-}"
[ -z "${VERSION}" ] && VERSION="${V8_VERSION}"

PREFIX="${LIB_ROOT}/out/${TARGET}"
V8_SRC="${LIB_ROOT}/v8-src"
DIST="${LIB_ROOT}/dist"
PKG_NAME="$(pkg_name "${PACKAGE_NAME:-v8}" "${VERSION}" "${TARGET}")"
STAGE="${DIST}/${PKG_NAME}"

[ -d "${PREFIX}/lib" ] || die "未找到构建产物 ${PREFIX}/lib，请先运行 build_unix.sh ${TARGET}"
[ -d "${PREFIX}/libcxx/include" ] || die "未找到 ${PREFIX}/libcxx/include，请先用 use_custom_libcxx 构建"
[ -f "${PREFIX}/libcxx/include/__config_site" ] || die "缺少 ${PREFIX}/libcxx/include/__config_site"

# 读取 build_unix.sh 写入的 libc++ 元数据
CUSTOM_LIBCXX="true"
LIBCXX_MERGED="unknown"
if [ -f "${PREFIX}/LIBCXX_META.txt" ]; then
  # shellcheck disable=SC1090
  source "${PREFIX}/LIBCXX_META.txt"
fi

rm -rf "${STAGE}"
mkdir -p "${STAGE}/lib"

# V8 头文件与静态库
cp -R "${PREFIX}/include" "${STAGE}/include"
find "${PREFIX}/lib" -maxdepth 1 -type f \( -name '*.a' -o -name '*.lib' \) -exec cp {} "${STAGE}/lib/" \;

# Chromium custom libc++ / libc++abi
cp -R "${PREFIX}/libcxx" "${STAGE}/libcxx"
if [ -d "${PREFIX}/libcxxabi" ]; then
  cp -R "${PREFIX}/libcxxabi" "${STAGE}/libcxxabi"
fi

[ -f "${STAGE}/lib/libv8_monolith.a" ] || die "打包缺少 libv8_monolith.a"
[ -f "${STAGE}/libcxx/include/__config_site" ] || die "打包缺少 libcxx/include/__config_site"

# thin archive 不可发布；custom libc++ 包必须带 thick libc++.a
is_thin_a() {
  local f="$1"
  [ -f "${f}" ] || return 1
  local magic
  magic="$(head -c 8 "${f}" 2>/dev/null | tr -d '\0' || true)"
  case "${magic}" in *thin*) return 0 ;; *) return 1 ;; esac
}
is_thin_a "${STAGE}/lib/libv8_monolith.a" && die "拒绝发布 thin libv8_monolith.a（主库成员 .o 不在包内）"
[ -f "${STAGE}/lib/libc++.a" ] || die "打包缺少 thick lib/libc++.a (libcxx_merged=${LIBCXX_MERGED})"
is_thin_a "${STAGE}/lib/libc++.a" && die "拒绝发布 thin libc++.a（需 thick）"
if [ -f "${STAGE}/lib/libc++abi.a" ]; then
  is_thin_a "${STAGE}/lib/libc++abi.a" && die "拒绝发布 thin libc++abi.a（需 thick）"
fi

# 许可证
copy_license "${V8_SRC}" "${STAGE}" "v8"
for lic in \
  "${V8_SRC}/third_party/libc++/src/LICENSE.TXT" \
  "${V8_SRC}/third_party/libc++/LICENSE.TXT" \
  "${V8_SRC}/buildtools/third_party/libc++/LICENSE.TXT"
do
  if [ -f "${lic}" ]; then
    cp "${lic}" "${STAGE}/LICENSE-libcxx"
    break
  fi
done
for lic in \
  "${V8_SRC}/third_party/libc++abi/src/LICENSE.TXT" \
  "${V8_SRC}/third_party/libc++abi/LICENSE.TXT" \
  "${V8_SRC}/buildtools/third_party/libc++abi/LICENSE.TXT"
do
  if [ -f "${lic}" ]; then
    cp "${lic}" "${STAGE}/LICENSE-libcxxabi"
    break
  fi
done

# Android: 从 gclient 自带的 NDK 读取 revision（工具链参考；STL 已改用 custom libc++）。
read_v8_ndk_revision() {
  local props="${V8_SRC}/third_party/android_toolchain/ndk/source.properties"
  local rev=""
  if [ -f "${props}" ]; then
    rev="$(grep -E '^Pkg\.Revision' "${props}" | head -1 | sed 's/.*= *//' | tr -d ' \r' || true)"
  fi
  if [ -z "${rev}" ] && [ -f "${V8_SRC}/DEPS" ]; then
    rev="$(sed -n "s/.*'android_ndk_version'[[:space:]]*:[[:space:]]*Str('\([^']*\)').*/\1/p" \
      "${V8_SRC}/DEPS" | head -1 || true)"
  fi
  rev="${rev##*@}"
  echo "${rev}"
}

BUILD_INFO_ARGS=(
  "Package     : ${PKG_NAME}"
  "Target      : ${TARGET}"
  "v8          : ${V8_VERSION}"
  "i18n        : ${V8_ENABLE_I18N}"
  "webassembly : ${V8_ENABLE_WEBASSEMBLY}"
  "temporal    : ${V8_ENABLE_TEMPORAL}"
  "ptr_compr   : ${ENABLE_POINTER_COMPRESSION}"
  "symbol_level: ${SYMBOL_LEVEL}"
  "for_shared  : ${V8_MONOLITHIC_FOR_SHARED_LIBRARY:-true}"
  "cppgc_caged : ${V8_ENABLE_CPPGC_CAGED_HEAP:-false}"
  "cppgc_caged_comment : false=关 caged heap/young gen/cppgc 指针压缩，下游勿定义 CPPGC_* 宏；true=恢复 V8 默认，下游须定义 CPPGC_POINTER_COMPRESSION"
  "custom_libcxx : ${CUSTOM_LIBCXX}"
  "libcxx_merged : ${LIBCXX_MERGED}"
  "libcxx_comment : 下游必须用包内 libcxx/include (+ libcxxabi/include) 编译；ABI=std::__Cr。务必另链 thick lib/libc++.a（及 libc++abi.a 若存在）；禁止 thin archive"
)

case "${TARGET}" in
  android-*)
    NDK_REVISION="$(read_v8_ndk_revision)"
    [ -n "${NDK_REVISION}" ] || warn "未解析到 NDK revision，BUILD_INFO 将省略 ndk_revision"
    [ -n "${NDK_REVISION}" ] && BUILD_INFO_ARGS+=("ndk_revision: ${NDK_REVISION}")
    BUILD_INFO_ARGS+=("android_api : ${ANDROID_API}")
    ;;
esac

BUILD_INFO_ARGS+=("Linkage     : static (v8_monolith)")

write_build_info "${STAGE}/BUILD_INFO.txt" "${BUILD_INFO_ARGS[@]}"

# 下游用法摘要
cat > "${STAGE}/LIBCXX_USAGE.txt" <<'EOF'
Chromium custom libc++ (use_custom_libcxx=true)
===============================================

本包 V8 以 std::__Cr ABI 编译。下游 C++ 代码若调用 V8 公开 API 中的
std:: 类型（如 unique_ptr），必须使用本包附带的 libc++，不可混用系统
libstdc++ / 系统 libc++ (std::__1)。

编译示例 (clang/gcc):
  -nostdinc++
  -isystem ${V8_ROOT}/libcxx/include
  -isystem ${V8_ROOT}/libcxxabi/include   # 若存在
  -I${V8_ROOT}/include

链接:
  ${V8_ROOT}/lib/libv8_monolith.a
  ${V8_ROOT}/lib/libc++.a              # 必须：thick，禁止 !<thin>
  ${V8_ROOT}/lib/libc++abi.a           # 若包内存在

验收提示:
  - nm/llvm-nm 对 NewDefaultPlatform  demangle 应含 __Cr
  - 包内存在 libcxx/include/__config_site
EOF

mkdir -p "${DIST}"
make_archive "tar.gz" "${DIST}" "${PKG_NAME}"
