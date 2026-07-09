#!/usr/bin/env bash
# =============================================================================
# V8 打包脚本 (Unix: macOS / Linux / Android)
#
# 将 v8/out/<target>/{include,lib} 连同许可证与构建信息打包为 tar.gz。
# 复用 scripts/common.sh 的打包骨架，保证与其它库命名/结构一致。
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

VERSION="${PACKAGE_VERSION:-}"
[ -z "${VERSION}" ] && VERSION="${V8_VERSION}"

PREFIX="${LIB_ROOT}/out/${TARGET}"
V8_SRC="${LIB_ROOT}/v8-src"
DIST="${LIB_ROOT}/dist"
PKG_NAME="$(pkg_name "${PACKAGE_NAME:-v8}" "${VERSION}" "${TARGET}")"
STAGE="${DIST}/${PKG_NAME}"

[ -d "${PREFIX}/lib" ] || die "未找到构建产物 ${PREFIX}/lib，请先运行 build_unix.sh ${TARGET}"

rm -rf "${STAGE}"
mkdir -p "${STAGE}/lib"

# 头文件与静态库
cp -R "${PREFIX}/include" "${STAGE}/include"
find "${PREFIX}/lib" -maxdepth 1 -type f -name '*.a' -exec cp {} "${STAGE}/lib/" \;

[ -f "${STAGE}/lib/libv8_monolith.a" ] || die "打包缺少 libv8_monolith.a"

# 许可证
copy_license "${V8_SRC}" "${STAGE}" "v8"

# Android: 从 gclient 自带的 NDK 读取 revision，便于下游对齐 NDK / libc++。
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
  # DEPS 值形如 CIPD 版本 "2@30.0.14608247"，剥掉 "<n>@" 前缀，与 source.properties 对齐。
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
  "ptr_compr   : ${V8_ENABLE_POINTER_COMPRESSION}"
  "symbol_level: ${SYMBOL_LEVEL}"
  "for_shared  : ${V8_MONOLITHIC_FOR_SHARED_LIBRARY:-true}"
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

# 构建信息
write_build_info "${STAGE}/BUILD_INFO.txt" "${BUILD_INFO_ARGS[@]}"

mkdir -p "${DIST}"
make_archive "tar.gz" "${DIST}" "${PKG_NAME}"
