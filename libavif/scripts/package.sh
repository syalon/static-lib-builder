#!/usr/bin/env bash
# =============================================================================
# 打包脚本 (Unix)
#
# 将 out/<target>/{include,lib} 连同许可证与构建信息打包为 tar.gz。
#
# 用法:
#   scripts/package.sh <target>
#
# 产物: dist/libavif-dav1d-<version>-<target>.tar.gz
# =============================================================================
set -euo pipefail

TARGET="${1:?用法: package.sh <target>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/config.env"

VERSION="${PACKAGE_VERSION:-}"
[ -z "${VERSION}" ] && VERSION="${LIBAVIF_VERSION}"

PREFIX="${REPO_ROOT}/out/${TARGET}"
WORK="${REPO_ROOT}/work/${TARGET}"
DIST="${REPO_ROOT}/dist"
PKG_NAME="${PACKAGE_NAME:-libavif-dav1d}-${VERSION}-${TARGET}"
STAGE="${DIST}/${PKG_NAME}"

if [ ! -d "${PREFIX}/lib" ]; then
  echo "错误: 未找到构建产物 ${PREFIX}/lib，请先运行 build_unix.sh ${TARGET}" >&2
  exit 1
fi

rm -rf "${STAGE}"
mkdir -p "${STAGE}"

# --- 复制头文件与静态库 -------------------------------------------------------
cp -R "${PREFIX}/include" "${STAGE}/include"
mkdir -p "${STAGE}/lib"
# 只收集静态库，忽略 cmake/pkgconfig 之外的多余文件
find "${PREFIX}/lib" -maxdepth 1 -type f \( -name '*.a' -o -name '*.lib' \) -exec cp {} "${STAGE}/lib/" \;
# 一并附带 pkgconfig，方便下游用 pkg-config 链接
if [ -d "${PREFIX}/lib/pkgconfig" ]; then
  cp -R "${PREFIX}/lib/pkgconfig" "${STAGE}/lib/pkgconfig"
fi

# --- 许可证 -------------------------------------------------------------------
copy_license() {
  local src="$1" name="$2"
  for f in LICENSE LICENSE.txt COPYING COPYING.txt; do
    if [ -f "${src}/${f}" ]; then
      cp "${src}/${f}" "${STAGE}/LICENSE-${name}"
      return
    fi
  done
}
copy_license "${WORK}/libavif" "libavif"
copy_license "${WORK}/dav1d" "dav1d"

# --- 构建信息 -----------------------------------------------------------------
cat > "${STAGE}/BUILD_INFO.txt" <<EOF
Package     : ${PKG_NAME}
Target      : ${TARGET}
libavif     : ${LIBAVIF_VERSION}
dav1d       : ${DAV1D_VERSION}
libyuv      : ${ENABLE_LIBYUV}
Codec       : dav1d (decode only)
Linkage     : static
Built (UTC) : $(date -u '+%Y-%m-%d %H:%M:%S')
Built by    : build-libavif-libdav1d GitHub Actions
EOF

# --- 打包 ---------------------------------------------------------------------
mkdir -p "${DIST}"
tar -czf "${DIST}/${PKG_NAME}.tar.gz" -C "${DIST}" "${PKG_NAME}"
rm -rf "${STAGE}"

echo "==> 打包完成: ${DIST}/${PKG_NAME}.tar.gz"
ls -lh "${DIST}/${PKG_NAME}.tar.gz"
