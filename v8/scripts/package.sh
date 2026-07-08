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

# 构建信息
TLS_INFO="n/a"
case "${TARGET}" in
  linux-x86_64|android-arm64-v8a) TLS_INFO="${V8_TLS_MODEL:-global-dynamic}" ;;
esac

write_build_info "${STAGE}/BUILD_INFO.txt" \
  "Package     : ${PKG_NAME}" \
  "Target      : ${TARGET}" \
  "v8          : ${V8_VERSION}" \
  "i18n        : ${V8_ENABLE_I18N}" \
  "webassembly : ${V8_ENABLE_WEBASSEMBLY}" \
  "temporal    : ${V8_ENABLE_TEMPORAL}" \
  "ptr_compr   : ${V8_ENABLE_POINTER_COMPRESSION}" \
  "symbol_level: ${SYMBOL_LEVEL}" \
  "tls_model   : ${TLS_INFO}" \
  "Linkage     : static (v8_monolith)"

mkdir -p "${DIST}"
make_archive "tar.gz" "${DIST}" "${PKG_NAME}"
