<#
=============================================================================
 V8 构建脚本 (Windows, MSVC / clang-cl)

 用法:
   pwsh v8/scripts/build_windows.ps1 -Target windows-x64-msvc

 自包含流程 (与 libavif 的 build_windows.ps1 风格一致):
   depot_tools -> gclient sync -> checkout 版本 -> gn gen -> ninja v8_monolith
   -> 收集 include + v8_monolith.lib + Chromium libc++ 头/库 -> 打包为 zip

 依赖 (由 CI 预先安装): Visual Studio 2022 (含 C++ 工具链), git, Python。
 使用 runner 自带 VS: 设置 DEPOT_TOOLS_WIN_TOOLCHAIN=0。

 产物: v8\out\<Target>\{include, lib\v8_monolith.lib, libcxx\, libcxxabi\}
       v8\dist\<PACKAGE_NAME>-<version>-<Target>.zip
=============================================================================
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Target = "windows-x64-msvc"
)

$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param([scriptblock]$Block)
    & $Block
    if ($LASTEXITCODE -ne 0) { throw "命令失败，退出码 $LASTEXITCODE" }
}

function Find-FirstExistingPath {
    param([string[]]$Candidates)
    foreach ($c in $Candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

# --- 解析目录并加载 config.env ----------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LibRoot   = (Resolve-Path (Join-Path $ScriptDir "..")).Path

$Cfg = @{}
Get-Content (Join-Path $LibRoot "config.env") | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $kv = $line.Split("=", 2)
        $Cfg[$kv[0].Trim()] = $kv[1].Trim()
    }
}

# 配置以 config.env 为唯一来源。
function Get-Cfg([string]$Key, [string]$Default) {
    if ($Cfg.ContainsKey($Key) -and $Cfg[$Key]) { return $Cfg[$Key] }
    return $Default
}

$PackageName = Get-Cfg "PACKAGE_NAME" "v8"
$V8Version   = Get-Cfg "V8_VERSION" ""
if (-not $V8Version) { throw "config.env 缺少 V8_VERSION" }
$PkgVersion  = Get-Cfg "PACKAGE_VERSION" $V8Version

$IsDebug      = Get-Cfg "IS_DEBUG" "false"
$SymbolLevel  = Get-Cfg "SYMBOL_LEVEL" "0"
$EnableI18n   = Get-Cfg "V8_ENABLE_I18N" "false"
$EnableWasm   = Get-Cfg "V8_ENABLE_WEBASSEMBLY" "true"
$EnableTemporal = Get-Cfg "V8_ENABLE_TEMPORAL" "false"
$EnablePtrCmp = Get-Cfg "V8_ENABLE_POINTER_COMPRESSION_WINDOWS" "false"
if ($EnablePtrCmp -notin @("true", "false")) {
    throw "不支持的 V8_ENABLE_POINTER_COMPRESSION_WINDOWS=$EnablePtrCmp (可选: true, false)"
}
$EnableCppgcCaged = Get-Cfg "V8_ENABLE_CPPGC_CAGED_HEAP" "false"
$ForSharedLib = Get-Cfg "V8_MONOLITHIC_FOR_SHARED_LIBRARY" "true"

$DepotTools = Join-Path $LibRoot "depot_tools"
$V8Src      = Join-Path $LibRoot "v8-src"
$Prefix     = Join-Path $LibRoot "out\$Target"
$GnBase     = Join-Path $LibRoot "gn_args\$Target.gn"
$OutDir     = "out\$Target"   # 相对 V8Src
$Jobs       = [Environment]::ProcessorCount

if (-not (Test-Path $GnBase)) { throw "未找到 gn 基础参数 $GnBase" }

Write-Host "==> Target  : $Target"
Write-Host "==> V8      : $V8Version"
Write-Host "==> Prefix  : $Prefix"

# --- 1) depot_tools ----------------------------------------------------------
if (-not (Test-Path (Join-Path $DepotTools ".git"))) {
    Write-Host "==> 获取 depot_tools"
    Invoke-Checked { git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git $DepotTools }
}
$env:PATH = "$DepotTools;$env:PATH"
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
# 首次运行 gclient 触发 bootstrap (下载 Python 等)
Invoke-Checked { cmd /c "gclient --version" }

# --- 2) gclient 配置 + 检出 --------------------------------------------------
Push-Location $LibRoot
if (-not (Test-Path (Join-Path $LibRoot ".gclient"))) {
    Write-Host "==> gclient config (checkout 名 v8-src)"
    Invoke-Checked { cmd /c "gclient config --name v8-src --unmanaged https://chromium.googlesource.com/v8/v8.git" }
}
if (-not (Test-Path (Join-Path $V8Src ".git"))) {
    Invoke-Checked { git clone https://chromium.googlesource.com/v8/v8.git $V8Src }
}
Write-Host "==> 检出 V8 版本: $V8Version"
Invoke-Checked { git -C $V8Src fetch --tags --depth 1 origin $V8Version }
Invoke-Checked { git -C $V8Src checkout $V8Version }
Write-Host "==> gclient sync (可能耗时较久)"
Invoke-Checked { cmd /c "gclient sync --nohooks --no-history --shallow -D" }
Invoke-Checked { cmd /c "gclient runhooks" }
Pop-Location

$PatchFile = Join-Path $LibRoot "patches\$V8Version-fix-msvc-no-pointer-compression.patch"
if (-not (Test-Path $PatchFile)) { throw "未找到当前 V8 版本的补丁: $PatchFile" }

$PatchTemp = Join-Path ([IO.Path]::GetTempPath()) "v8-$V8Version-msvc-layout.patch"
$PatchText = [IO.File]::ReadAllText($PatchFile).Replace("`r`n", "`n")
[IO.File]::WriteAllText($PatchTemp, $PatchText, [Text.UTF8Encoding]::new($false))

try {
    # actions/checkout 在 Windows 上可能将仓库内补丁转成 CRLF；先规范化为 LF，
    # 再忽略源码 checkout 的行尾空白差异，确保 git apply 跨平台稳定。
    & git -C $V8Src apply --reverse --check --ignore-space-change --ignore-whitespace $PatchTemp *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "==> V8 补丁已应用: $(Split-Path -Leaf $PatchFile)"
    } else {
        & git -C $V8Src apply --check --ignore-space-change --ignore-whitespace $PatchTemp *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "V8 补丁无法应用，请检查补丁是否匹配 V8 ${V8Version}: $PatchFile"
        }
        Write-Host "==> 应用 V8 补丁: $(Split-Path -Leaf $PatchFile)"
        Invoke-Checked {
            git -C $V8Src apply --ignore-space-change --ignore-whitespace $PatchTemp
        }
    }
} finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $PatchTemp
}

# --- 3) 合成 args.gn ---------------------------------------------------------
$OutFull = Join-Path $V8Src $OutDir
New-Item -ItemType Directory -Force -Path $OutFull | Out-Null
$ArgsGn  = Join-Path $OutFull "args.gn"
$argsContent = @()
$argsContent += "# 自动生成，请勿手改。基础参数见 v8/gn_args/$Target.gn，可调项见 v8/config.env"
$argsContent += (Get-Content $GnBase)
$argsContent += ""
$argsContent += "# --- 可调参数 (来自 config.env) ---"
$argsContent += "is_debug = $IsDebug"
$argsContent += "symbol_level = $SymbolLevel"
$argsContent += "v8_enable_i18n_support = $EnableI18n"
$argsContent += "v8_enable_webassembly = $EnableWasm"
$argsContent += "v8_enable_temporal_support = $EnableTemporal"
$argsContent += "v8_enable_pointer_compression = $EnablePtrCmp"
$argsContent += "v8_monolithic_for_shared_library = $ForSharedLib"
$argsContent += ""
$argsContent += "# --- 固定参数 (产出单一静态库) ---"
$argsContent += "v8_monolithic = true"
$argsContent += "is_component_build = false"
$argsContent += "v8_use_external_startup_data = false"
$argsContent += "treat_warnings_as_errors = false"
# 已启用 use_custom_libcxx=true（见 gn_args），sandbox 所需的 libc++ 加固可用；
# 但仍为嵌入场景关闭 sandbox。与指针压缩相互独立。
$argsContent += "v8_enable_sandbox = false"
# cppgc caged heap 开关，由 config.env V8_ENABLE_CPPGC_CAGED_HEAP 控制。64bit 上默认开，BUILD.gn
# 会据此强制 cppgc 指针压缩=true，令库带宏 CPPGC_POINTER_COMPRESSION 编译；此宏决定公开头文件里
# cppgc::Member 布局，下游若不定义同样的宏会布局错位并在初始化 cppgc 堆时崩。关掉后连带关掉
# young generation 与 cppgc 指针压缩，相关外部宏全部不定义，与"下游不定义任何 cppgc 宏"对齐。
# 此项独立于主堆的 v8_enable_pointer_compression (V8_COMPRESS_POINTERS)。
$argsContent += "cppgc_enable_caged_heap = $EnableCppgcCaged"
Set-Content -Path $ArgsGn -Value $argsContent -Encoding UTF8

Write-Host "==> 生成的 args.gn:"
Get-Content $ArgsGn | ForEach-Object { "    $_" }

# --- 4) gn gen + ninja -------------------------------------------------------
Push-Location $V8Src
Invoke-Checked { cmd /c "gn gen $OutDir" }
Invoke-Checked { cmd /c "ninja -C $OutDir -j $Jobs v8_monolith" }
Pop-Location

# --- 5) 收集产物 -------------------------------------------------------------
$Monolith = Join-Path $OutFull "obj\v8_monolith.lib"
if (-not (Test-Path $Monolith)) { throw "未找到 $Monolith" }

if (Test-Path $Prefix) { Remove-Item -Recurse -Force $Prefix }
New-Item -ItemType Directory -Force -Path (Join-Path $Prefix "lib") | Out-Null
Copy-Item $Monolith (Join-Path $Prefix "lib\v8_monolith.lib")
Copy-Item -Recurse (Join-Path $V8Src "include") (Join-Path $Prefix "include")

# --- 5b) Chromium custom libc++ / libc++abi ---------------------------------
$LibcxxInc = Find-FirstExistingPath @(
    (Join-Path $V8Src "third_party\libc++\src\include")
    (Join-Path $V8Src "buildtools\third_party\libc++\trunk\include")
    (Join-Path $V8Src "buildtools\third_party\libc++\include")
)
if (-not $LibcxxInc) { throw "未找到 libc++ 头文件目录 (use_custom_libcxx=true 需要打包)" }

$ConfigSite = Find-FirstExistingPath @(
    (Join-Path $V8Src "buildtools\third_party\libc++\__config_site")
    (Join-Path $OutFull "gen\buildtools\third_party\libc++\__config_site")
    (Join-Path $OutFull "gen\third_party\libc++\src\include\__config_site")
)
if (-not $ConfigSite) { throw "未找到 libc++ __config_site (ABI 命名空间定义)" }

$LibcxxAbiInc = Find-FirstExistingPath @(
    (Join-Path $V8Src "third_party\libc++abi\src\include")
    (Join-Path $V8Src "buildtools\third_party\libc++abi\trunk\include")
    (Join-Path $V8Src "buildtools\third_party\libc++abi\include")
)

$StageLibcxx = Join-Path $Prefix "libcxx\include"
New-Item -ItemType Directory -Force -Path $StageLibcxx | Out-Null
Copy-Item -Recurse -Force (Join-Path $LibcxxInc "*") $StageLibcxx
Copy-Item -Force $ConfigSite (Join-Path $StageLibcxx "__config_site")

if ($LibcxxAbiInc) {
    $StageAbi = Join-Path $Prefix "libcxxabi\include"
    New-Item -ItemType Directory -Force -Path $StageAbi | Out-Null
    Copy-Item -Recurse -Force (Join-Path $LibcxxAbiInc "*") $StageAbi
}

# 方案 1: 探测 v8_monolith.lib 是否已包含 libc++ 目标文件
#   用 llvm-nm / dumpbin 看 __libcpp_verbose_abort 是 T/D(已定义) 还是 U(未定义)
$LibcxxMerged = $false
$NmCmd = Get-Command llvm-nm -ErrorAction SilentlyContinue
if ($NmCmd) {
    $nmOut = & llvm-nm -g $Monolith 2>$null | Select-String -Pattern ' [TD] _?__libcpp_verbose_abort'
    if ($nmOut) {
        $LibcxxMerged = $true
        Write-Host "==> libc++ 已并入 v8_monolith.lib (libcxx_merged=true)"
    }
} else {
    $Dumpbin = Get-Command dumpbin -ErrorAction SilentlyContinue
    if ($Dumpbin) {
        $dbOut = & dumpbin /SYMBOLS $Monolith 2>$null | Select-String -Pattern '__libcpp_verbose_abort'
        if ($dbOut -and ($dbOut | Where-Object { $_ -notmatch '\bUNDEF\b' })) {
            $LibcxxMerged = $true
            Write-Host "==> libc++ 已并入 v8_monolith.lib (libcxx_merged=true, via dumpbin)"
        }
    } else {
        Write-Host "==> WARN: 无 llvm-nm/dumpbin，无法探测 libc++ 是否并入 monolith"
    }
}

# 方案 2: 未并入则附带独立 .lib
if (-not $LibcxxMerged) {
    Write-Host "==> libc++ 未并入 monolith，收集独立 .lib (libcxx_merged=false)"
    $libDir = Join-Path $Prefix "lib"
    $searchRoots = @(
        (Join-Path $OutFull "obj\buildtools\third_party\libc++")
        (Join-Path $OutFull "obj\buildtools\third_party\libc++abi")
        (Join-Path $OutFull "obj\third_party\libc++")
        (Join-Path $OutFull "obj\third_party\libc++abi")
    )
    $copied = 0
    foreach ($root in $searchRoots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem -Path $root -Recurse -Filter "*.lib" -ErrorAction SilentlyContinue | ForEach-Object {
            $name = $_.Name
            if ($name -match '^(libc\+\+|libc\+\+abi|libc\+\+experimental)') {
                Copy-Item -Force $_.FullName (Join-Path $libDir $name)
                Write-Host "    附带 $name"
                $copied++
            }
        }
    }
    # 也接受 ninja 直接产出的 libc++.lib
    foreach ($extra in @(
        (Join-Path $OutFull "obj\buildtools\third_party\libc++\libc++.lib")
        (Join-Path $OutFull "obj\buildtools\third_party\libc++abi\libc++abi.lib")
    )) {
        if (Test-Path $extra) {
            Copy-Item -Force $extra (Join-Path $libDir (Split-Path -Leaf $extra))
            Write-Host "    附带 $(Split-Path -Leaf $extra)"
            $copied++
        }
    }
    if ($copied -eq 0) {
        Write-Host "==> WARN: 未找到独立 libc++.lib；下游链接可能缺少 __libcpp_verbose_abort 等符号"
    }
}

if (-not (Test-Path (Join-Path $Prefix "libcxx\include\__config_site"))) {
    throw "验收失败: 缺少 libcxx/include/__config_site"
}

# --- 6) 打包为 zip -----------------------------------------------------------
$Dist    = Join-Path $LibRoot "dist"
$PkgName = "$PackageName-$PkgVersion-$Target"
$Stage   = Join-Path $Dist $PkgName
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "lib") | Out-Null

Copy-Item -Recurse (Join-Path $Prefix "include") (Join-Path $Stage "include")
Copy-Item -Recurse (Join-Path $Prefix "libcxx") (Join-Path $Stage "libcxx")
if (Test-Path (Join-Path $Prefix "libcxxabi")) {
    Copy-Item -Recurse (Join-Path $Prefix "libcxxabi") (Join-Path $Stage "libcxxabi")
}
Get-ChildItem (Join-Path $Prefix "lib") -File | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $Stage "lib\$($_.Name)")
}

# 许可证
foreach ($f in @("LICENSE", "LICENSE.txt", "COPYING")) {
    $p = Join-Path $V8Src $f
    if (Test-Path $p) { Copy-Item $p (Join-Path $Stage "LICENSE-v8"); break }
}
foreach ($lic in @(
    (Join-Path $V8Src "third_party\libc++\src\LICENSE.TXT")
    (Join-Path $V8Src "third_party\libc++\LICENSE.TXT")
    (Join-Path $V8Src "buildtools\third_party\libc++\LICENSE.TXT")
)) {
    if (Test-Path $lic) { Copy-Item $lic (Join-Path $Stage "LICENSE-libcxx"); break }
}
foreach ($lic in @(
    (Join-Path $V8Src "third_party\libc++abi\src\LICENSE.TXT")
    (Join-Path $V8Src "third_party\libc++abi\LICENSE.TXT")
    (Join-Path $V8Src "buildtools\third_party\libc++abi\LICENSE.TXT")
)) {
    if (Test-Path $lic) { Copy-Item $lic (Join-Path $Stage "LICENSE-libcxxabi"); break }
}

$LibcxxMergedStr = if ($LibcxxMerged) { "true" } else { "false" }
$BuildInfo = @"
Package     : $PkgName
Target      : $Target
v8          : $V8Version
i18n        : $EnableI18n
webassembly : $EnableWasm
temporal    : $EnableTemporal
ptr_compr   : $EnablePtrCmp
symbol_level: $SymbolLevel
for_shared  : $ForSharedLib
cppgc_caged : $EnableCppgcCaged
cppgc_caged_comment : false=关 caged heap/young gen/cppgc 指针压缩，下游勿定义 CPPGC_* 宏；true=恢复 V8 默认，下游须定义 CPPGC_POINTER_COMPRESSION
custom_libcxx : true
libcxx_merged : $LibcxxMergedStr
libcxx_comment : 下游必须用包内 libcxx/include (+ libcxxabi/include) 编译；ABI 命名空间 std::__Cr。libcxx_merged=true 时只链 v8_monolith.lib；false 时另链 lib/libc++.lib
Linkage     : static (v8_monolith)
Built (UTC) : $((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss"))
Built by    : GitHub Actions (build-static-libs)
"@
Set-Content -Path (Join-Path $Stage "BUILD_INFO.txt") -Value $BuildInfo -Encoding UTF8

$Usage = @"
Chromium custom libc++ (use_custom_libcxx=true)
===============================================

本包 V8 以 std::__Cr ABI 编译（clang-cl）。下游 C++ 代码若调用 V8 公开 API
中的 std:: 类型，必须使用本包附带的 libc++，不可混用 MSVC STL。

编译示例 (clang-cl / MSVC 风格):
  -Xclang -nostdinc++
  -imsvc ${V8_ROOT}/libcxx/include
  -imsvc ${V8_ROOT}/libcxxabi/include   # 若存在
  -I${V8_ROOT}/include

或 clang:
  -nostdinc++
  -isystem ${V8_ROOT}/libcxx/include
  -isystem ${V8_ROOT}/libcxxabi/include
  -I${V8_ROOT}/include

链接:
  ${V8_ROOT}/lib/v8_monolith.lib
  # 若 BUILD_INFO 中 libcxx_merged=false，再加 lib/libc++.lib (及 libc++abi.lib)

验收提示:
  - demangle NewDefaultPlatform 应含 __Cr
  - 包内存在 libcxx/include/__config_site
"@
Set-Content -Path (Join-Path $Stage "LIBCXX_USAGE.txt") -Value $Usage -Encoding UTF8

$Zip = Join-Path $Dist "$PkgName.zip"
if (Test-Path $Zip) { Remove-Item -Force $Zip }
Compress-Archive -Path $Stage -DestinationPath $Zip
Remove-Item -Recurse -Force $Stage

Write-Host "==> 打包完成: $Zip"
Get-ChildItem $Zip | Format-List
