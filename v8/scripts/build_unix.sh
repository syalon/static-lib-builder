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
  macos-arm64|macos-x86_64)
    ENABLE_POINTER_COMPRESSION="${V8_ENABLE_POINTER_COMPRESSION_MACOS:?config.env 缺少 V8_ENABLE_POINTER_COMPRESSION_MACOS}"
    ;;
  linux-x86_64)
    ENABLE_POINTER_COMPRESSION="${V8_ENABLE_POINTER_COMPRESSION_LINUX:?config.env 缺少 V8_ENABLE_POINTER_COMPRESSION_LINUX}"
    ;;
  android-arm64-v8a)
    ENABLE_POINTER_COMPRESSION="${V8_ENABLE_POINTER_COMPRESSION_ANDROID:?config.env 缺少 V8_ENABLE_POINTER_COMPRESSION_ANDROID}"
    ;;
  *) die "build_unix.sh 不支持的 target: ${TARGET} (Windows 请用 build_windows.ps1)" ;;
esac

case "${ENABLE_POINTER_COMPRESSION}" in
  true|false) ;;
  *) die "不支持的指针压缩配置: ${ENABLE_POINTER_COMPRESSION} (可选: true, false)" ;;
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

case "${V8_MONOLITHIC_FOR_SHARED_LIBRARY:-true}" in
  true|false) ;;
  *) die "不支持的 V8_MONOLITHIC_FOR_SHARED_LIBRARY=${V8_MONOLITHIC_FOR_SHARED_LIBRARY} (可选: true, false)" ;;
esac

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
  echo "v8_enable_temporal_support = ${V8_ENABLE_TEMPORAL}"
  echo "v8_enable_pointer_compression = ${ENABLE_POINTER_COMPRESSION}"
  echo "v8_monolithic_for_shared_library = ${V8_MONOLITHIC_FOR_SHARED_LIBRARY:-true}"
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
  # cppgc (Oilpan / C++ 堆) 的 caged heap 开关，由 config.env V8_ENABLE_CPPGC_CAGED_HEAP 控制。
  # 背景: 64bit (arm64/x64) 上默认开，BUILD.gn 会据此"强制" cppgc_enable_pointer_compression
  #       =true (无法单独关)，库会带宏 CPPGC_POINTER_COMPRESSION 编译，此宏决定公开头文件里
  #       cppgc::Member / v8::TracedReference 的布局。下游若不定义同样的宏 -> 布局错位 ->
  #       初始化 cppgc 堆时崩溃 (典型: Android 启动即崩)。
  # 关掉后连带关闭 young generation 与 cppgc 指针压缩，相关外部宏全部不定义，与"下游不定义
  #       任何 cppgc 宏"对齐。此项独立于主堆的 v8_enable_pointer_compression (V8_COMPRESS_POINTERS)。
  echo "cppgc_enable_caged_heap = ${V8_ENABLE_CPPGC_CAGED_HEAP:-false}"
} > "${ARGS_GN}"

if [ "${TARGET}" = "android-arm64-v8a" ]; then
  echo "default_min_sdk_version = ${ANDROID_API}" >> "${ARGS_GN}"
fi

# Linux: 验收 isolate.o 不含 TPOFF (local-exec) 重定位，确保可链入 .so。
verify_linux_tls_reloc() {
  local for_shared="${V8_MONOLITHIC_FOR_SHARED_LIBRARY:-true}"
  [ "${TARGET}" = "linux-x86_64" ] || return 0
  [ "${for_shared}" = "true" ] || return 0

  local isolate_o
  # 追加 || true: 多匹配时 head 提前关管道会让 find 收到 SIGPIPE，pipefail 下会误退出。
  isolate_o="$(find "${V8_SRC}/${OUT_DIR}/obj" -name 'isolate.o' -path '*/execution/*' 2>/dev/null | head -1 || true)"
  if [ -z "${isolate_o}" ]; then
    log "WARN: 未找到 isolate.o，跳过 TLS 验收"
    return 0
  fi

  local tpoff_count=0
  if command -v llvm-readobj >/dev/null 2>&1; then
    tpoff_count="$(llvm-readobj --relocs "${isolate_o}" 2>/dev/null | grep -c 'TPOFF' || true)"
  elif command -v readelf >/dev/null 2>&1; then
    tpoff_count="$(readelf -r "${isolate_o}" 2>/dev/null | grep -c 'TPOFF' || true)"
  else
    log "WARN: 无 llvm-readobj/readelf，跳过 TLS 验收"
    return 0
  fi

  if [ "${tpoff_count}" -gt 0 ]; then
    die "TLS 验收失败: ${isolate_o} 含 ${tpoff_count} 个 TPOFF 重定位 (local-exec)，无法链入 .so。请确认 V8_MONOLITHIC_FOR_SHARED_LIBRARY=true 并全量重编 (rm -rf v8/v8-src/out/${TARGET})。"
  fi
  log "TLS 验收通过: isolate.o 无 TPOFF 重定位"
}

log "生成的 args.gn:"
sed 's/^/    /' "${ARGS_GN}"

# --- gn gen + ninja ----------------------------------------------------------
cd "${V8_SRC}"
log "gn gen ${OUT_DIR}"
gn gen "${OUT_DIR}"

log "ninja v8_monolith"
ninja -C "${OUT_DIR}" -j "${JOBS}" v8_monolith

verify_linux_tls_reloc

# --- 收集产物 ----------------------------------------------------------------
MONOLITH="${V8_SRC}/${OUT_DIR}/obj/libv8_monolith.a"
[ -f "${MONOLITH}" ] || die "未找到 ${MONOLITH}"

rm -rf "${PREFIX}"
mkdir -p "${PREFIX}/lib" "${PREFIX}/include"
cp "${MONOLITH}" "${PREFIX}/lib/libv8_monolith.a"
cp -R "${V8_SRC}/include/." "${PREFIX}/include/"

log "完成: 产物位于 ${PREFIX}"
ls -lhR "${PREFIX}" | head -n 40 || true
