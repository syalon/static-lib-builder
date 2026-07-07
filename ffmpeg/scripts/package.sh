#!/usr/bin/env bash
# =============================================================================
# 打包 FFmpeg minimal static 产物
#
# 用法: bash ffmpeg/scripts/package.sh <target>
# 产物: ffmpeg/dist/ffmpeg-minimal-<ver>-<target>.tar.gz  (MSVC 用 .zip)
# =============================================================================
set -euo pipefail

TARGET="${1:?用法: package.sh <target>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${LIB_ROOT}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/common.sh"
load_env "${LIB_ROOT}/config.env"

VERSION="${PACKAGE_VERSION:-}"
[ -z "${VERSION}" ] && VERSION="${FFMPEG_VERSION}"

PREFIX="${LIB_ROOT}/out/${TARGET}"
WORK="${LIB_ROOT}/work/${TARGET}"
DIST="${LIB_ROOT}/dist"
PKG_NAME="$(pkg_name "${PACKAGE_NAME}" "${VERSION}" "${TARGET}")"
STAGE="${DIST}/${PKG_NAME}"

[ -d "${PREFIX}/lib" ] || die "未找到 ${PREFIX}/lib，请先 build_unix.sh ${TARGET}"

rm -rf "${STAGE}"
mkdir -p "${STAGE}/lib"
cp -R "${PREFIX}/include" "${STAGE}/include"
find "${PREFIX}/lib" -maxdepth 1 -type f \( -name '*.a' -o -name '*.lib' \) -exec cp {} "${STAGE}/lib/" \;

copy_license "${WORK}/FFmpeg" "${STAGE}" "ffmpeg"

write_build_info "${STAGE}/BUILD_INFO.txt" \
  "Package     : ${PKG_NAME}" \
  "Target      : ${TARGET}" \
  "FFmpeg      : release/${FFMPEG_VERSION}" \
  "Profile     : minimal (internal engine video module)" \
  "Decoders    : ${FFMPEG_DECODERS}" \
  "Demuxers    : ${FFMPEG_DEMUXERS}" \
  "Parsers     : ${FFMPEG_PARSERS}" \
  "Protocols   : ${FFMPEG_PROTOCOLS}" \
  "Libraries   : avcodec avformat swscale swresample avutil (static)" \
  "Linkage     : static"

mkdir -p "${DIST}"
case "${TARGET}" in
  windows-x64-msvc)
    make_archive zip "${DIST}" "${PKG_NAME}"
    ;;
  *)
    make_archive tar.gz "${DIST}" "${PKG_NAME}"
    ;;
esac
