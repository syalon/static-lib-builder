#!/usr/bin/env bash
# =============================================================================
# 收集 Chromium custom libc++ / libc++abi 头文件，并产出可发布的 thick 静态库。
#
# 背景 (真实 blocker):
#   1) Chromium 默认 thin archive (`!<thin>`)，只含 .o 路径；拷进 zip/tar 后废档。
#   2) v8_monolith 通常不并入 libc++（`__libcpp_verbose_abort` 为 U）。
#   3) Windows 上 libc++ 是 source_set，根本没有 libc++.lib，必须从 .obj 组库。
#
# 主路径 (现行):
#   build_unix.sh 在 gn gen 前调用 disable_thin_archive.py 置空
#   //build/config/compiler:thin_archive，V8 于是直接产出 thick libc++.a。
#   本脚本对 thick 源只做 cp（见 _thicken_archive），不再跑脆弱的 thin->thick 转换。
#
# 兜底: 万一仍拿到 thin（补丁未生效等），保留 MRI / 成员解析 / 从 .o 组库逻辑。
#
# 策略: 始终产出 thick lib/libc++.a (+ libc++abi.a)，libcxx_merged 如实记录；
#       缺库 / 仍为 thin / 缺关键符号 → 构建失败。
#
# 用法 (由 build_unix.sh source):
#   collect_libcxx <v8_src> <out_dir_rel> <prefix>
#
# 输出变量:
#   LIBCXX_MERGED=true|false
# =============================================================================

_libcxx_resolve_tool() {
  # $1 = llvm-ar | llvm-nm
  local name="$1"
  if [ -n "${V8_SRC_FOR_AR:-}" ] \
    && [ -x "${V8_SRC_FOR_AR}/third_party/llvm-build/Release+Asserts/bin/${name}" ]; then
    echo "${V8_SRC_FOR_AR}/third_party/llvm-build/Release+Asserts/bin/${name}"
    return 0
  fi
  if command -v "${name}" >/dev/null 2>&1; then
    command -v "${name}"
    return 0
  fi
  return 1
}

# 选用 ar（优先 Chromium llvm-ar，能处理 thin / @rsp）
_libcxx_ar() {
  local ar_bin
  if ar_bin="$(_libcxx_resolve_tool llvm-ar)"; then
    :
  else
    ar_bin="ar"
  fi
  "${ar_bin}" "$@"
}

_is_thin_archive() {
  local f="$1"
  [ -f "${f}" ] || return 1
  # thin: "!<thin>\n"  thick: "!<arch>\n"
  local magic
  magic="$(head -c 8 "${f}" 2>/dev/null | tr -d '\0' || true)"
  case "${magic}" in
    *thin*) return 0 ;;
    *) return 1 ;;
  esac
}

# 探测对象/静态库架构（跨 ELF/Mach-O/COFF/bitcode）。输出规范名或空。
# 主路径: detect_arch.py（快、无依赖）；对其无法识别者（典型: macOS wrapped
# bitcode、arm64 CPU_TYPE_ANY）用系统工具兜底（lipo/readelf/file），确保交叉
# 编译时能可靠区分 host 与 target 架构。
_LIBCXX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_file_arch_syscmd() {
  local f="$1"
  # macOS: lipo 能处理 .o / .a / bitcode
  if command -v lipo >/dev/null 2>&1; then
    local out
    out="$(lipo -archs "${f}" 2>/dev/null | tr ' ' '\n' | head -1 || true)"
    case "${out}" in
      arm64|arm64e) echo "aarch64"; return 0 ;;
      x86_64|x86_64h) echo "x86_64"; return 0 ;;
      i386) echo "i386"; return 0 ;;
    esac
  fi
  # Linux: readelf（对普通 ELF 对象/可执行；archive 由 detect_arch.py 处理）
  if command -v readelf >/dev/null 2>&1; then
    local m
    m="$(readelf -h "${f}" 2>/dev/null | sed -n 's/.*Machine:[[:space:]]*//p' | head -1 || true)"
    case "${m}" in
      *X86-64*|*x86-64*) echo "x86_64"; return 0 ;;
      *AArch64*|*aarch64*) echo "aarch64"; return 0 ;;
      *80386*) echo "i386"; return 0 ;;
      *ARM*) echo "arm"; return 0 ;;
    esac
  fi
  # 通用: file
  if command -v file >/dev/null 2>&1; then
    local d
    d="$(file -b "${f}" 2>/dev/null || true)"
    case "${d}" in
      *x86-64*|*x86_64*) echo "x86_64"; return 0 ;;
      *aarch64*|*arm64*|*ARM64*) echo "aarch64"; return 0 ;;
      *80386*|*i386*) echo "i386"; return 0 ;;
    esac
  fi
  return 0
}

_file_arch() {
  local f="$1"
  [ -f "${f}" ] || return 1
  local arch="" py=""
  if command -v python3 >/dev/null 2>&1; then
    py="python3"
  elif command -v python >/dev/null 2>&1; then
    py="python"
  fi
  if [ -n "${py}" ]; then
    arch="$("${py}" "${_LIBCXX_SCRIPT_DIR}/detect_arch.py" "${f}" 2>/dev/null || true)"
  fi
  if [ -n "${arch}" ] && [ "${arch}" != "unknown" ]; then
    echo "${arch}"; return 0
  fi
  # detect_arch 未识别 → 系统工具兜底
  _file_arch_syscmd "${f}"
}

# 用 @rsp 或分批写入，避免 ARG_MAX（libc++ 目标文件可达数百个）
_libcxx_ar_rcs() {
  local dest="$1"
  shift
  local objs=("$@")
  [ "${#objs[@]}" -gt 0 ] || return 1
  mkdir -p "$(dirname "${dest}")"
  rm -f "${dest}"

  local ar_bin rsp
  if ar_bin="$(_libcxx_resolve_tool llvm-ar)"; then
    rsp="$(mktemp)"
    # llvm-ar @file: 按 GNU 命令行分词并识别引号，路径加引号以容忍空格
    local o
    for o in "${objs[@]}"; do
      printf '"%s"\n' "${o}"
    done > "${rsp}"
    if "${ar_bin}" rcs "${dest}" "@${rsp}"; then
      rm -f "${rsp}"
      return 0
    fi
    rm -f "${rsp}"
    # 个别旧 llvm-ar 不认 @file，回退分批；清理可能的半成品避免 q 追加到损坏库
    rm -f "${dest}"
  fi

  # 分批: 先建空库再 q 追加（每批 80 个）
  local batch=()
  local i=0
  local o
  for o in "${objs[@]}"; do
    batch+=("${o}")
    i=$((i + 1))
    if [ "${#batch[@]}" -ge 80 ]; then
      if [ ! -f "${dest}" ]; then
        _libcxx_ar rcs "${dest}" "${batch[@]}"
      else
        _libcxx_ar qS "${dest}" "${batch[@]}" 2>/dev/null \
          || _libcxx_ar q "${dest}" "${batch[@]}"
      fi
      batch=()
    fi
  done
  if [ "${#batch[@]}" -gt 0 ]; then
    if [ ! -f "${dest}" ]; then
      _libcxx_ar rcs "${dest}" "${batch[@]}"
    else
      _libcxx_ar qS "${dest}" "${batch[@]}" 2>/dev/null \
        || _libcxx_ar q "${dest}" "${batch[@]}"
    fi
  fi
  # 写符号表
  _libcxx_ar s "${dest}" 2>/dev/null || true
  [ -f "${dest}" ]
}

# 将 thin/thick 源库写成 thick 目标库到 dest。
# out_root: 构建 out 目录，用于解析 thin 成员相对路径。
_thicken_archive() {
  local src="$1"
  local dest="$2"
  local out_root="$3"

  [ -f "${src}" ] || die "_thicken_archive: 源不存在 ${src}"
  mkdir -p "$(dirname "${dest}")"
  rm -f "${dest}"

  if ! _is_thin_archive "${src}"; then
    cp -f "${src}" "${dest}"
    return 0
  fi

  log "  转换 thin -> thick: $(basename "${src}")"

  # 首选: llvm-ar MRI 脚本 ADDLIB —— 由 llvm-ar 自行解析 thin 成员并写入完整对象，
  # 无需手工推断相对路径。thin 成员按构建目录 (out_root) 相对存储，故须在其下运行。
  local ar_bin dest_abs src_abs
  if ar_bin="$(_libcxx_resolve_tool llvm-ar)"; then
    case "${dest}" in /*) dest_abs="${dest}" ;; *) dest_abs="$(pwd)/${dest}" ;; esac
    case "${src}" in
      /*) src_abs="${src}" ;;
      *) src_abs="$(cd "$(dirname "${src}")" && pwd)/$(basename "${src}")" ;;
    esac
    if ( cd "${out_root}" && "${ar_bin}" -M ) 2>/dev/null <<EOF
CREATE ${dest_abs}
ADDLIB ${src_abs}
SAVE
END
EOF
    then
      if [ -f "${dest}" ] && ! _is_thin_archive "${dest}"; then
        return 0
      fi
    fi
    rm -f "${dest}"
    log "  MRI 方式未成功，回退到成员路径解析"
  fi

  # 回退: 解析 thin 成员路径逐个组库
  local members=()
  local m cand resolved
  while IFS= read -r m; do
    [ -n "${m}" ] || continue
    # 跳过符号表伪成员
    case "${m}" in
      /|/SYM64/|__.SYMDEF*) continue ;;
    esac
    resolved=""
    if [ -f "${m}" ]; then
      resolved="${m}"
    else
      for cand in \
        "${out_root}/${m}" \
        "$(dirname "${src}")/${m}" \
        "${out_root}/obj/${m}"
      do
        if [ -f "${cand}" ]; then
          resolved="${cand}"
          break
        fi
      done
      # 末路: 按 basename 递归查找（应对相对基准目录不一致）
      if [ -z "${resolved}" ]; then
        resolved="$(find "${out_root}" -type f -name "$(basename "${m}")" 2>/dev/null | head -1 || true)"
      fi
    fi
    [ -n "${resolved}" ] || die "thin archive 成员缺失: ${m} (来自 ${src})"
    members+=("${resolved}")
  done < <(_libcxx_ar t "${src}" 2>/dev/null)

  [ "${#members[@]}" -gt 0 ] || die "thin archive 无成员: ${src}"
  _libcxx_ar_rcs "${dest}" "${members[@]}" || die "thick 组库失败: ${dest}"
  _is_thin_archive "${dest}" && die "thick 转换失败仍为 thin: ${dest}"
}

_create_archive_from_objs() {
  local dest="$1"
  shift
  local objs=("$@")
  [ "${#objs[@]}" -gt 0 ] || return 1
  _libcxx_ar_rcs "${dest}" "${objs[@]}" || return 1
  _is_thin_archive "${dest}" && die "新建 archive 意外为 thin: ${dest}"
  return 0
}

# archive 中是否已定义某符号 (类型非 U/u，含 weak W/V 等)
# 返回: 0=已定义, 1=未定义, 2=无工具
_archive_defines_symbol() {
  local archive="$1"
  local sym="$2"
  local nm_bin=""
  if ! nm_bin="$(_libcxx_resolve_tool llvm-nm)"; then
    if command -v nm >/dev/null 2>&1; then
      nm_bin="$(command -v nm)"
    else
      return 2  # 无 nm 工具
    fi
  fi
  # 类型字符取除 U/u 外的任意字母 (T/D/R/S/B/W/V/G/C ...)，覆盖 weak 符号。
  # 关键: __libcpp_verbose_abort 在 namespace std(__Cr) 内，会被 mangle 成
  #   __ZNSt4__Cr22__libcpp_verbose_abortEPKcz，符号名嵌在 mangled 串中间，
  #   故不能要求它紧跟类型字符，用 .* 允许任意前缀（mangling）。
  #   ` [type] ` 的空格边界只会命中类型字段，U/u 已被排除，不会误判未定义行。
  "${nm_bin}" -g "${archive}" 2>/dev/null \
    | grep -E " [A-TV-Za-tv-z] .*${sym}" >/dev/null
}

_require_symbol_or_die() {
  local archive="$1"
  local sym="$2"
  local label="$3"
  local rc=0
  _archive_defines_symbol "${archive}" "${sym}" || rc=$?
  if [ "${rc}" -eq 2 ]; then
    die "验收失败: 无 llvm-nm/nm，无法验证 ${label} 是否含 ${sym}"
  fi
  if [ "${rc}" -ne 0 ]; then
    return 1
  fi
  return 0
}

# 收集 libc++ / libc++abi 的 .o/.obj（递归全树，覆盖交叉编译的工具链子目录）
# $3 ref_arch: 目标架构（来自 monolith）。交叉编译时构建树含 host 与 target 两份
# libc++，必须按架构过滤，只留与 monolith 一致的对象，否则会把 host 架构 .o 误打包。
_find_libcxx_objs() {
  local out_full="$1"
  local which="$2"
  local ref_arch="${3:-}"
  local all
  all="$(_find_libcxx_objs_raw "${out_full}" "${which}")"
  [ -n "${all}" ] || return 0

  # 有参考架构时按架构挑选。两级:
  #   tier1: 默认工具链 obj/ 目录（GN 保证=目标架构）——arch 匹配或无法判定都接受，
  #          这样即使个别文件探测失败（如 bitcode）也不会漏掉目标对象。
  #   tier2: 全树范围内严格 arch 匹配（用于目标 libc++ 不在 obj/ 直下的情形）。
  # host/sim 工具链一律在 ${out_full}/<toolchain>/obj/ 子目录下，不会落入 tier1。
  if [ -n "${ref_arch}" ]; then
    local o oa obj_hits="" arch_hits=""
    while IFS= read -r o; do
      [ -n "${o}" ] || continue
      oa="$(_file_arch "${o}")"
      case "${o}" in
        "${out_full}/obj/"*)
          if [ -z "${oa}" ] || [ "${oa}" = "${ref_arch}" ]; then
            obj_hits+="${o}"$'\n'
          fi
          ;;
      esac
      [ "${oa}" = "${ref_arch}" ] && arch_hits+="${o}"$'\n'
    done <<< "${all}"
    [ -n "${obj_hits}" ]  && { printf '%s' "${obj_hits}";  return 0; }
    [ -n "${arch_hits}" ] && { printf '%s' "${arch_hits}"; return 0; }
    # 无匹配：返回空，交由调用方处理，绝不打包错架构。
    return 0
  fi

  local preferred
  preferred="$(printf '%s\n' "${all}" | grep -E "^${out_full}/obj/" || true)"
  if [ -n "${preferred}" ]; then
    printf '%s\n' "${preferred}"
  else
    printf '%s\n' "${all}"
  fi
}

_find_libcxx_objs_raw() {
  local out_full="$1"
  local which="$2"
  find "${out_full}" -type f \( -name '*.o' -o -name '*.obj' \) 2>/dev/null \
    | while IFS= read -r f; do
        case "${which}" in
          libcxx)
            case "${f}" in */libc++abi/*) continue ;; esac
            case "${f}" in
              */buildtools/third_party/libc++/*|*/third_party/libc++/*) echo "${f}" ;;
            esac
            ;;
          libcxxabi)
            case "${f}" in */libc++abi/*) echo "${f}" ;; esac
            ;;
        esac
      done
}

# 递归查找 libc++.a / libc++abi.a。
# $3 ref_arch: 目标架构（来自 monolith）。交叉编译树里同时有 host/target 两份库，
# 必须按架构精确匹配，杜绝把 host 架构库误当 target 打包。
_find_named_archive() {
  local out_full="$1"
  local name="$2"        # libc++.a | libc++abi.a
  local ref_arch="${3:-}"
  local f fa
  # 优先默认工具链 obj/ 下的常规位置。此处 obj/ 是 GN 默认工具链输出 = 目标架构，
  # 故 arch 匹配或“无法判定”（如 thin/bitcode 探测失败）都采用；仅当探测出的架构
  # 明确不一致时才跳过（防御性，正常不会发生）。
  for f in \
    "${out_full}/obj/buildtools/third_party/libc++/${name}" \
    "${out_full}/obj/buildtools/third_party/libc++abi/${name}" \
    "${out_full}/obj/third_party/libc++/${name}" \
    "${out_full}/obj/third_party/libc++abi/${name}"
  do
    [ -f "${f}" ] || continue
    if [ -z "${ref_arch}" ]; then
      echo "${f}"; return 0
    fi
    fa="$(_file_arch "${f}")"
    if [ -z "${fa}" ] || [ "${fa}" = "${ref_arch}" ]; then
      echo "${f}"; return 0
    fi
  done

  # 递归全树。有参考架构：只接受架构一致者；无参考架构：退回“优先 obj/”。
  local best=""
  while IFS= read -r f; do
    case "${f}" in
      */buildtools/third_party/libc++*|*/third_party/libc++*|*/libc++/*|*/libc++abi/*) ;;
      *) continue ;;
    esac
    if [ -n "${ref_arch}" ]; then
      fa="$(_file_arch "${f}")"
      [ "${fa}" = "${ref_arch}" ] && { echo "${f}"; return 0; }
      continue
    fi
    case "${f}" in
      "${out_full}/obj/"*) echo "${f}"; return 0 ;;
    esac
    [ -z "${best}" ] && best="${f}"
  done < <(find "${out_full}" -type f -name "${name}" 2>/dev/null || true)
  [ -n "${best}" ] && { echo "${best}"; return 0; }
  return 1
}

# 产出 thick libc++.a / libc++abi.a 到 prefix/lib。
# $3 merged: monolith 是否已含 libc++（true 时找不到独立库不致命）。
# $4 ref_arch: 目标架构（来自 monolith），用于交叉编译时精确挑选同架构 libc++。
_package_libcxx_libs() {
  local out_full="$1"
  local prefix="$2"
  local merged="${3:-false}"
  local ref_arch="${4:-}"
  local dest_dir="${prefix}/lib"
  mkdir -p "${dest_dir}"

  local src_cxx="" src_abi=""
  src_cxx="$(_find_named_archive "${out_full}" "libc++.a" "${ref_arch}" || true)"
  src_abi="$(_find_named_archive "${out_full}" "libc++abi.a" "${ref_arch}" || true)"

  if [ -n "${src_cxx}" ]; then
    _thicken_archive "${src_cxx}" "${dest_dir}/libc++.a" "${out_full}"
    log "  已打包 thick libc++.a (from ${src_cxx})"
  else
    log "  未找到匹配架构(${ref_arch:-any})的 libc++.a，尝试从 .o 组 thick 库"
    local objs=()
    while IFS= read -r o; do
      [ -n "${o}" ] && objs+=("${o}")
    done < <(_find_libcxx_objs "${out_full}" libcxx "${ref_arch}")
    if [ "${#objs[@]}" -eq 0 ]; then
      log "  诊断: out 目录下 libc++ 相关文件及其探测架构（期望=${ref_arch:-any}）:"
      local _dpath _darch
      while IFS= read -r _dpath; do
        [ -n "${_dpath}" ] || continue
        _darch="$(_file_arch "${_dpath}")"
        printf '    [%s] %s\n' "${_darch:-未知}" "${_dpath}" >&2
      done < <(find "${out_full}" -path '*libc++*' \
        \( -name '*.a' -o -name '*.o' -o -name '*.obj' \) 2>/dev/null | head -n 60)
      if [ "${merged}" = "true" ]; then
        warn "未找到独立 libc++（架构=${ref_arch:-any}），但已并入 monolith，跳过独立库"
        return 0
      fi
      die "无法产出 libc++.a：无匹配架构(${ref_arch:-any})的 archive 或 .o"
    fi
    _create_archive_from_objs "${dest_dir}/libc++.a" "${objs[@]}" \
      || die "从 .o 创建 libc++.a 失败"
    log "  已从 ${#objs[@]} 个 .o 组 thick libc++.a"
  fi

  if [ -n "${src_abi}" ]; then
    _thicken_archive "${src_abi}" "${dest_dir}/libc++abi.a" "${out_full}"
    log "  已打包 thick libc++abi.a (from ${src_abi})"
  else
    local abi_objs=()
    while IFS= read -r o; do
      [ -n "${o}" ] && abi_objs+=("${o}")
    done < <(_find_libcxx_objs "${out_full}" libcxxabi "${ref_arch}")
    if [ "${#abi_objs[@]}" -gt 0 ]; then
      _create_archive_from_objs "${dest_dir}/libc++abi.a" "${abi_objs[@]}" \
        || die "从 .o 创建 libc++abi.a 失败"
      log "  已从 ${#abi_objs[@]} 个 .o 组 thick libc++abi.a"
    else
      log "  未找到独立 libc++abi（可能已链入 libc++），跳过"
    fi
  fi

  # 硬验收: thick + 关键符号
  [ -f "${dest_dir}/libc++.a" ] || die "验收失败: 缺少 ${dest_dir}/libc++.a"
  _is_thin_archive "${dest_dir}/libc++.a" && die "验收失败: libc++.a 仍为 thin archive"
  if [ -f "${dest_dir}/libc++abi.a" ]; then
    _is_thin_archive "${dest_dir}/libc++abi.a" && die "验收失败: libc++abi.a 仍为 thin archive"
  fi

  # 硬验收: 架构必须与 monolith 一致（拦截交叉编译误打 host 架构 libc++）。
  if [ -n "${ref_arch}" ]; then
    local got
    got="$(_file_arch "${dest_dir}/libc++.a")"
    if [ -n "${got}" ] && [ "${got}" != "${ref_arch}" ]; then
      die "验收失败: libc++.a 架构=${got} 与 monolith=${ref_arch} 不一致（交叉编译错配）"
    fi
    if [ -z "${got}" ]; then
      warn "无法探测 libc++.a 架构（缺 python?），跳过架构验收；期望=${ref_arch}"
    else
      log "  验收通过: libc++.a 架构=${got} 与 monolith 一致"
    fi
    if [ -f "${dest_dir}/libc++abi.a" ]; then
      local got_abi
      got_abi="$(_file_arch "${dest_dir}/libc++abi.a")"
      if [ -n "${got_abi}" ] && [ "${got_abi}" != "${ref_arch}" ]; then
        die "验收失败: libc++abi.a 架构=${got_abi} 与 monolith=${ref_arch} 不一致"
      fi
    fi
  fi

  if _require_symbol_or_die "${dest_dir}/libc++.a" "__libcpp_verbose_abort" "libc++.a"; then
    log "  验收通过: libc++.a 定义了 __libcpp_verbose_abort"
  elif [ -f "${dest_dir}/libc++abi.a" ] \
    && _require_symbol_or_die "${dest_dir}/libc++abi.a" "__libcpp_verbose_abort" "libc++abi.a"; then
    log "  验收通过: __libcpp_verbose_abort 定义于 libc++abi.a"
  else
    die "验收失败: thick libc++ 未定义 __libcpp_verbose_abort（下游无法链接）"
  fi
}

collect_libcxx() {
  local v8_src="${1:?}"
  local out_dir="${2:?}"
  local prefix="${3:?}"
  local out_full="${v8_src}/${out_dir}"
  V8_SRC_FOR_AR="${v8_src}"

  LIBCXX_MERGED="false"

  # --- 定位头文件源 ----------------------------------------------------------
  local libcxx_inc=""
  for cand in \
    "${v8_src}/third_party/libc++/src/include" \
    "${v8_src}/buildtools/third_party/libc++/trunk/include" \
    "${v8_src}/buildtools/third_party/libc++/include"
  do
    if [ -d "${cand}" ] && { [ -f "${cand}/__config" ] || [ -f "${cand}/vector" ]; }; then
      libcxx_inc="${cand}"
      break
    fi
  done
  [ -n "${libcxx_inc}" ] || die "未找到 libc++ 头文件目录 (use_custom_libcxx=true 需要打包)"

  local config_site=""
  for cand in \
    "${v8_src}/buildtools/third_party/libc++/__config_site" \
    "${out_full}/gen/buildtools/third_party/libc++/__config_site" \
    "${out_full}/gen/third_party/libc++/src/include/__config_site"
  do
    if [ -f "${cand}" ]; then
      config_site="${cand}"
      break
    fi
  done
  [ -n "${config_site}" ] || die "未找到 libc++ __config_site (ABI 命名空间定义)"

  local libcxxabi_inc=""
  for cand in \
    "${v8_src}/third_party/libc++abi/src/include" \
    "${v8_src}/buildtools/third_party/libc++abi/trunk/include" \
    "${v8_src}/buildtools/third_party/libc++abi/include"
  do
    if [ -d "${cand}" ]; then
      libcxxabi_inc="${cand}"
      break
    fi
  done

  # --- 复制头文件 ------------------------------------------------------------
  mkdir -p "${prefix}/libcxx/include"
  cp -R "${libcxx_inc}/." "${prefix}/libcxx/include/"
  cp "${config_site}" "${prefix}/libcxx/include/__config_site"

  if [ -n "${libcxxabi_inc}" ]; then
    mkdir -p "${prefix}/libcxxabi/include"
    cp -R "${libcxxabi_inc}/." "${prefix}/libcxxabi/include/"
  fi

  # --- 探测 monolith 是否已并入 libc++（仅元数据；始终仍打包 thick 库）------
  local monolith=""
  for cand in \
    "${out_full}/obj/libv8_monolith.a" \
    "${prefix}/lib/libv8_monolith.a"
  do
    if [ -f "${cand}" ]; then
      monolith="${cand}"
      break
    fi
  done
  [ -n "${monolith}" ] || die "collect_libcxx: 未找到 libv8_monolith.a"

  # 主库若是 thin archive，打包后成员 .o 丢失，整包不可用——直接失败。
  _is_thin_archive "${monolith}" \
    && die "验收失败: libv8_monolith.a 为 thin archive，不可发布 (检查 v8_monolithic/complete_static_lib)"

  # 目标架构以 monolith 为准；交叉编译时据此精确挑选同架构 libc++。
  local ref_arch
  ref_arch="$(_file_arch "${monolith}")"
  if [ -n "${ref_arch}" ]; then
    log "目标架构 (monolith): ${ref_arch}"
  else
    warn "无法探测 monolith 架构（缺 python?），libc++ 收集将退回路径优先，无法拦截交叉编译错配"
  fi

  local rc=0
  _archive_defines_symbol "${monolith}" "__libcpp_verbose_abort" || rc=$?
  if [ "${rc}" -eq 0 ]; then
    LIBCXX_MERGED="true"
    log "libc++ 符号已出现在 libv8_monolith.a (libcxx_merged=true)；仍附带 thick libc++ 供下游显式链接"
  else
    LIBCXX_MERGED="false"
    if [ "${rc}" -eq 2 ]; then
      log "WARN: 无 llvm-nm/nm，无法探测 monolith 是否并入 libc++，按 libcxx_merged=false 处理"
    else
      log "libc++ 未并入 monolith (libcxx_merged=false)，打包独立 thick 静态库"
    fi
  fi

  # 尽量附带 thick libc++；merged=true 时找不到独立库不致命（下游链 monolith 即可）
  _package_libcxx_libs "${out_full}" "${prefix}" "${LIBCXX_MERGED}" "${ref_arch}"

  [ -f "${prefix}/libcxx/include/__config_site" ] \
    || die "验收失败: 缺少 ${prefix}/libcxx/include/__config_site"
  if [ -f "${prefix}/lib/libc++.a" ]; then
    _is_thin_archive "${prefix}/lib/libc++.a" && die "验收失败: lib/libc++.a 为 thin，不可发布"
  elif [ "${LIBCXX_MERGED}" != "true" ]; then
    die "验收失败: 缺少 lib/libc++.a 且 libc++ 未并入 monolith"
  fi

  if grep -q '_LIBCPP_ABI_NAMESPACE' "${prefix}/libcxx/include/__config_site"; then
    log "ABI: $(grep '_LIBCPP_ABI_NAMESPACE' "${prefix}/libcxx/include/__config_site" | head -1 | tr -d '\r')"
  fi
}
