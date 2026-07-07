#!/usr/bin/env bash
# =============================================================================
# V8 构建脚本 (Unix: macOS / Linux / Android 交叉)
#
# 用法:
#   v8/scripts/build_unix.sh <target>
#
# 支持的 <target>:
#   macos-arm64          macOS Apple Silicon (native 或 arm runner 上 native)
#   macos-x86_64         macOS Intel (native 或 Apple Silicon 上交叉编译)
#   linux-x86_64         Linux x86_64 (native)
#   android-arm64-v8a    Android arm64 (NDK 交叉，NDK 由 gclient 自带)
#
# 前置: 已运行 v8/scripts/fetch.sh <target> 拉好源码。
#
# 流程: 由 gn_args/<target>.gn 基础参数 + config.env 可调参数合成 args.gn
#       -> gn gen -> ninja v8_monolith -> 收集到 out/<target>/{include,lib}
#
# 产物: v8/out/<target>/{include, lib/libv8_monolith.a}
# =============================================================================
set -euo pipefail

TARGET="${1:?用法: build_unix.sh <target>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${LIB_ROOT}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/common.sh"

# 所有配置以 config.env 为唯一来源。
load_env "${LIB_ROOT}/config.env"

case "${TARGET}" in
  macos-arm64|macos-x86_64|linux-x86_64|android-arm64-v8a) ;;
  *) die "build_unix.sh 不支持的 target: ${TARGET} (Windows 请用 build_windows.ps1)" ;;
esac

# 用 V8 自带 libc++ (use_custom_libcxx=true) 的目标: monolith 不含 libc++ 符号，
# 需把 libc++/libc++abi 合并进 monolith，产出自包含单一 .a。须与 gn_args/<target>.gn 一致。
# (macOS: Xcode SDK libc++ 与 partition_alloc 的 force-hidden new/delete 冲突;
#  Linux: bullseye sysroot 的 libstdc++ 太老、缺 std::bit_cast; 故两者都用自带 libc++。)
case "${TARGET}" in
  linux-x86_64|macos-arm64|macos-x86_64) USE_CUSTOM_LIBCXX=1 ;;
  *)                                     USE_CUSTOM_LIBCXX=0 ;;
esac

DEPOT_TOOLS="${LIB_ROOT}/depot_tools"
V8_SRC="${LIB_ROOT}/v8-src"
PREFIX="${LIB_ROOT}/out/${TARGET}"
GN_BASE="${LIB_ROOT}/gn_args/${TARGET}.gn"
OUT_DIR="out/${TARGET}"   # 相对 V8_SRC (gn 要求在源码树内)
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

[ -d "${V8_SRC}/.git" ] || die "未找到 V8 源码 ${V8_SRC}，请先运行 fetch.sh ${TARGET}"
[ -f "${GN_BASE}" ]     || die "未找到 gn 基础参数 ${GN_BASE}"

export PATH="${DEPOT_TOOLS}:${PATH}"
export DEPOT_TOOLS_WIN_TOOLCHAIN=0

log "Target       : ${TARGET}"
log "V8 版本      : ${V8_VERSION}"
log "Prefix       : ${PREFIX}"
log "并行任务数   : ${JOBS}"

# --- 合成 args.gn ------------------------------------------------------------
ARGS_GN="${V8_SRC}/${OUT_DIR}/args.gn"
mkdir -p "${V8_SRC}/${OUT_DIR}"
{
  echo "# 自动生成，请勿手改。基础参数见 v8/gn_args/${TARGET}.gn，可调项见 v8/config.env"
  cat "${GN_BASE}"
  echo ""
  echo "# --- 可调参数 (来自 config.env) ---"
  echo "is_debug = ${IS_DEBUG}"
  echo "symbol_level = ${SYMBOL_LEVEL}"
  echo "v8_enable_i18n_support = ${V8_ENABLE_I18N}"
  echo "v8_enable_webassembly = ${V8_ENABLE_WEBASSEMBLY}"
  echo "v8_enable_pointer_compression = ${V8_ENABLE_POINTER_COMPRESSION}"
  echo ""
  echo "# --- 固定参数 (产出单一静态库) ---"
  echo "v8_monolithic = true"
  echo "is_component_build = false"
  echo "v8_use_external_startup_data = false"
  echo "treat_warnings_as_errors = false"
  # 我们用系统/工具链 libc++ (use_custom_libcxx=false)，而 V8 sandbox 需要 libc++ 加固
  # (use_safe_libcxx，仅随 custom libcxx 提供)，两者冲突。嵌入场景关闭 sandbox。
  # 指针压缩与 sandbox 相互独立，关 sandbox 不影响 v8_enable_pointer_compression。
  echo "v8_enable_sandbox = false"
} > "${ARGS_GN}"

if [ "${TARGET}" = "android-arm64-v8a" ]; then
  echo "default_min_sdk_version = ${ANDROID_API}" >> "${ARGS_GN}"
fi

log "生成的 args.gn:"
sed 's/^/    /' "${ARGS_GN}"

# --- gn gen + ninja ----------------------------------------------------------
cd "${V8_SRC}"
log "gn gen ${OUT_DIR}"
gn gen "${OUT_DIR}"

log "ninja v8_monolith"
ninja -C "${OUT_DIR}" -j "${JOBS}" v8_monolith

# 自带 libc++ 的目标: static_library 不会自动构建其链接依赖，故显式再构建一次
# libc++/libc++abi 静态库，供下面合并进 monolith。
if [ "${USE_CUSTOM_LIBCXX}" = "1" ]; then
  log "ninja libc++ / libc++abi (用于合并进 monolith)"
  ninja -C "${OUT_DIR}" -j "${JOBS}" \
    "buildtools/third_party/libc++:libc++" \
    "buildtools/third_party/libc++abi:libc++abi" || true
fi

# --- 收集产物 ----------------------------------------------------------------
MONOLITH="${V8_SRC}/${OUT_DIR}/obj/libv8_monolith.a"
[ -f "${MONOLITH}" ] || die "未找到 ${MONOLITH}"

# v8_monolith.a 不含 libc++ 符号 (std::__1)，把 libc++/libc++abi 合并进来，
# 产出自包含的单一 .a。下游用系统工具链只链接 libv8_monolith.a 即可；
# 下游自身代码走系统 STL (Linux libstdc++ / macOS 系统 libc++) 与内部 libc++ 符号一般互不冲突。
# (若下游本身也用同版本 libc++，则可能符号重复，属已知取舍。)
if [ "${USE_CUSTOM_LIBCXX}" = "1" ]; then
  EXTRA_LIBS=()
  while IFS= read -r a; do
    if [ -n "${a}" ]; then
      EXTRA_LIBS+=("${a}")
    fi
  done < <(find "${V8_SRC}/${OUT_DIR}/obj" -type f \( -name 'libc++.a' -o -name 'libc++abi.a' \) 2>/dev/null)

  if [ "${#EXTRA_LIBS[@]}" -gt 0 ]; then
    AR_BIN="${V8_SRC}/third_party/llvm-build/Release+Asserts/bin/llvm-ar"
    [ -x "${AR_BIN}" ] || AR_BIN="ar"
    COMBINED="${V8_SRC}/${OUT_DIR}/obj/libv8_monolith_combined.a"
    rm -f "${COMBINED}"
    {
      echo "create ${COMBINED}"
      echo "addlib ${MONOLITH}"
      for a in "${EXTRA_LIBS[@]}"; do echo "addlib ${a}"; done
      echo "save"
      echo "end"
    } | "${AR_BIN}" -M
    [ -f "${COMBINED}" ] || die "合并 libc++ 失败: 未生成 ${COMBINED}"
    log "已合并 libc++ 到 monolith: ${EXTRA_LIBS[*]}"
    MONOLITH="${COMBINED}"
  else
    # libc++ 在非共享构建里常是 source_set，其目标文件已直接编进 libv8_monolith.a，
    # 此时找不到独立的 .a 属正常，monolith 本身已自包含。
    log "未发现独立 libc++.a/libc++abi.a (libc++ 多半已作为 source_set 编入 monolith)"
  fi
fi

rm -rf "${PREFIX}"
mkdir -p "${PREFIX}/lib" "${PREFIX}/include"
cp "${MONOLITH}" "${PREFIX}/lib/libv8_monolith.a"
cp -R "${V8_SRC}/include/." "${PREFIX}/include/"

log "完成: 产物位于 ${PREFIX}"
ls -lhR "${PREFIX}" | head -n 40 || true
