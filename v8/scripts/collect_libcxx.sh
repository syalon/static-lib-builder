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
  # 类型字符取除 U/u 外的任意字母 (T/D/R/S/B/W/V/G/C ...)，覆盖 weak 符号；
  # 符号名在行尾，用边界避免误匹配前缀相同的更长符号。
  "${nm_bin}" -g "${archive}" 2>/dev/null \
    | grep -E " [A-TV-Za-tv-z] _?${sym}([^A-Za-z0-9_]|$)" >/dev/null
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
# 为避免混入不同架构，优先默认工具链 (${out_full}/obj/，与 monolith 同架构)，
# 该处无对象时再回退整棵树。
_find_libcxx_objs() {
  local out_full="$1"
  local which="$2"  # libcxx | libcxxabi
  local all preferred
  all="$(_find_libcxx_objs_raw "${out_full}" "${which}")"
  [ -n "${all}" ] || return 0
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

# 递归查找 libc++.a / libc++abi.a，优先默认工具链 (${out_full}/obj/)。
_find_named_archive() {
  local out_full="$1"
  local name="$2"  # libc++.a | libc++abi.a
  local f
  for f in \
    "${out_full}/obj/buildtools/third_party/libc++/${name}" \
    "${out_full}/obj/buildtools/third_party/libc++abi/${name}" \
    "${out_full}/obj/third_party/libc++/${name}" \
    "${out_full}/obj/third_party/libc++abi/${name}"
  do
    if [ -f "${f}" ]; then
      echo "${f}"
      return 0
    fi
  done
  # 递归全树：优先默认工具链 obj/，否则取首个 libc++ 匹配。
  local best=""
  while IFS= read -r f; do
    case "${f}" in
      */buildtools/third_party/libc++*|*/third_party/libc++*|*/libc++/*|*/libc++abi/*) ;;
      *) continue ;;
    esac
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
_package_libcxx_libs() {
  local out_full="$1"
  local prefix="$2"
  local merged="${3:-false}"
  local dest_dir="${prefix}/lib"
  mkdir -p "${dest_dir}"

  local src_cxx="" src_abi=""
  src_cxx="$(_find_named_archive "${out_full}" "libc++.a" || true)"
  src_abi="$(_find_named_archive "${out_full}" "libc++abi.a" || true)"

  if [ -n "${src_cxx}" ]; then
    _thicken_archive "${src_cxx}" "${dest_dir}/libc++.a" "${out_full}"
    log "  已打包 thick libc++.a (from ${src_cxx})"
  else
    log "  未找到 libc++.a，尝试从 .o 组 thick 库"
    local objs=()
    while IFS= read -r o; do
      [ -n "${o}" ] && objs+=("${o}")
    done < <(_find_libcxx_objs "${out_full}" libcxx)
    if [ "${#objs[@]}" -eq 0 ]; then
      log "  诊断: out 目录下 libc++ 相关路径如下:"
      find "${out_full}" -path '*libc++*' \( -name '*.a' -o -name '*.o' -o -name '*.obj' \) \
        2>/dev/null | head -n 40 | sed 's/^/    /' >&2 || true
      if [ "${merged}" = "true" ]; then
        warn "未找到独立 libc++，但 libc++ 已并入 monolith，跳过独立库"
        return 0
      fi
      die "无法产出 libc++.a：无 archive 也无 .o（Windows source_set 请用 build_windows.ps1）"
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
    done < <(_find_libcxx_objs "${out_full}" libcxxabi)
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
  _package_libcxx_libs "${out_full}" "${prefix}" "${LIBCXX_MERGED}"

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
