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

# --- 关闭 thin archive（让静态库直接产出 thick，可分发）----------------------
# Chromium 默认给静态库套 //build/config/compiler:thin_archive（win 下 /llvmlibthin）。
# thin 归档只引用 .o，拷进产物包即失效。官方注释也说做可分发静态库须移除该 config。
Write-Host "==> 关闭 thin archive (build/config/compiler/BUILD.gn)"
$PyExe = $null
foreach ($p in @("python3", "python", "vpython3")) {
    $c = Get-Command $p -ErrorAction SilentlyContinue
    if ($c) { $PyExe = $c.Source; break }
}
if (-not $PyExe) { throw "未找到 python，无法关闭 thin archive" }
Invoke-Checked { & $PyExe (Join-Path $ScriptDir "disable_thin_archive.py") $V8Src }

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
# Windows 上 libc++ 是 source_set（无现成 libc++.lib），必须从 .obj 组库。
# 若偶有 .lib，也可能是 thin（/llvmlibthin），不可直接发布。
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

function Test-ArchiveDefinesSymbol {
    param([string]$Archive, [string]$Symbol)
    if (-not $Archive -or -not (Test-Path $Archive)) { return $false }
    $nmCandidates = @(
        (Join-Path $V8Src "third_party\llvm-build\Release+Asserts\bin\llvm-nm.exe")
        (Join-Path $V8Src "third_party\llvm-build\Release+Asserts\bin\llvm-nm")
    )
    $nm = $null
    foreach ($c in $nmCandidates) {
        if (Test-Path $c) { $nm = $c; break }
    }
    if (-not $nm) {
        $cmd = Get-Command llvm-nm -ErrorAction SilentlyContinue
        if ($cmd) { $nm = $cmd.Source }
    }
    if ($nm) {
        # 类型字符取除 U/u 外任意字母 (含 weak W/V)。__libcpp_verbose_abort 在
        # namespace std(__Cr) 内会被 mangle，符号名嵌在 mangled 串中间，故用 .*
        # 允许任意前缀；` [type] ` 空格边界只命中类型字段，不会误判未定义行。
        $hit = & $nm -g $Archive 2>$null | Select-String -Pattern " [A-TV-Za-tv-z] .*$Symbol"
        return [bool]$hit
    }
    $dumpbin = Get-Command dumpbin -ErrorAction SilentlyContinue
    if ($dumpbin) {
        $lines = & dumpbin /SYMBOLS $Archive 2>$null | Select-String -Pattern $Symbol
        if (-not $lines) { return $false }
        return [bool]($lines | Where-Object { $_ -notmatch '\bUNDEF\b' })
    }
    return $false
}

function Test-IsThinLib {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 8) { return $false }
    $magic = [Text.Encoding]::ASCII.GetString($bytes, 0, 8)
    return $magic -match 'thin'
}

function New-StaticLibFromObjs {
    param(
        [string]$OutLib,
        [string[]]$ObjFiles
    )
    if (-not $ObjFiles -or $ObjFiles.Count -eq 0) { return $false }
    $rsp = [IO.Path]::GetTempFileName()
    try {
        # 每行一个 obj，避免命令行过长
        $ObjFiles | ForEach-Object { "`"$_`"" } | Set-Content -Path $rsp -Encoding ASCII

        $candidates = @(
            (Join-Path $V8Src "third_party\llvm-build\Release+Asserts\bin\lld-link.exe")
            (Join-Path $V8Src "third_party\llvm-build\Release+Asserts\bin\lld-link")
        )
        $lld = $null
        foreach ($c in $candidates) {
            if (Test-Path $c) { $lld = $c; break }
        }
        if (-not $lld) {
            $cmd = Get-Command lld-link -ErrorAction SilentlyContinue
            if ($cmd) { $lld = $cmd.Source }
        }
        if ($lld) {
            & $lld /lib "/OUT:$OutLib" "@$rsp"
            if ($LASTEXITCODE -ne 0) { return $false }
            return (Test-Path $OutLib)
        }
        $libExe = Get-Command lib -ErrorAction SilentlyContinue
        if ($libExe) {
            & lib "/OUT:$OutLib" "@$rsp"
            if ($LASTEXITCODE -ne 0) { return $false }
            return (Test-Path $OutLib)
        }
        throw "未找到 lld-link 或 lib.exe，无法从 .obj 组 libc++.lib"
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $rsp
    }
}

function Find-LibcxxObjFiles {
    param([string]$OutFull, [ValidateSet("libcxx","libcxxabi")][string]$Which)
    $objRoot = Join-Path $OutFull "obj"
    if (-not (Test-Path $objRoot)) { return @() }
    # 不用 -Include（在部分 PowerShell 上不带尾随 * 会匹配不到）
    Get-ChildItem -Path $objRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $ext = $_.Extension.ToLowerInvariant()
        if ($ext -notin @('.obj', '.o')) { return $false }
        $p = $_.FullName
        if ($Which -eq "libcxx") {
            if ($p -match 'libc\+\+abi') { return $false }
            return ($p -match '[\\/]buildtools[\\/]third_party[\\/]libc\+\+[\\/]' `
                -or $p -match '[\\/]third_party[\\/]libc\+\+[\\/]')
        } else {
            return ($p -match 'libc\+\+abi')
        }
    } | ForEach-Object { $_.FullName }
}

# 判断某组 .obj 是否含 verbose_abort（__libcpp_verbose_abort 定义所在的 TU）。
# 这是比 Windows 上时好时坏的 nm/dumpbin 更可靠的“完整性”判据。
function Test-ObjsHaveVerboseAbort {
    param([string[]]$Objs)
    if (-not $Objs) { return $false }
    foreach ($o in $Objs) {
        if ([IO.Path]::GetFileName($o) -match 'verbose_abort') { return $true }
    }
    return $false
}

$libDir = Join-Path $Prefix "lib"
$destLib = Join-Path $libDir "libc++.lib"

# Windows 上 libc++ 是 source_set（无 libc++.lib），其所有 .obj（含 verbose_abort.obj）
# 会被完整链入 complete_static_lib 的 v8_monolith.lib，因此 monolith 天然自含 libc++。
# 我们额外从这些 .obj 组一份独立 thick libc++.lib，供下游单独链接。
$LibcxxObjs = @(Find-LibcxxObjFiles -OutFull $OutFull -Which libcxx)
$AbiObjs    = @(Find-LibcxxObjFiles -OutFull $OutFull -Which libcxxabi)

# 1) 若已有非 thin 现成 .lib，直接拷贝（一般 Windows 不会有）
$existing = @()
foreach ($root in @(
    (Join-Path $OutFull "obj\buildtools\third_party\libc++")
    (Join-Path $OutFull "obj\third_party\libc++")
)) {
    if (Test-Path $root) {
        $existing += @(Get-ChildItem -Path $root -Recurse -Filter "libc++.lib" -File -ErrorAction SilentlyContinue)
    }
}
$copied = $false
foreach ($e in $existing) {
    if (Test-IsThinLib $e.FullName) {
        Write-Host "    跳过 thin $($e.FullName)，改从 .obj 组库"
        continue
    }
    Copy-Item -Force $e.FullName $destLib
    Write-Host "    附带 thick libc++.lib (from $($e.FullName))"
    $copied = $true
    break
}

# 2) Windows source_set：从 .obj 组库（主路径）
if (-not $copied) {
    if ($LibcxxObjs.Count -eq 0) {
        throw "无法产出 libc++.lib：无现成库且未找到 libc++ .obj（source_set 产物）"
    }
    Write-Host "    从 $($LibcxxObjs.Count) 个 .obj 组 libc++.lib"
    if (-not (New-StaticLibFromObjs -OutLib $destLib -ObjFiles $LibcxxObjs)) {
        throw "从 .obj 创建 libc++.lib 失败"
    }
}

# 顺带组一份独立 libc++abi.lib（若有对应 obj）
$abiDest = Join-Path $libDir "libc++abi.lib"
if ($AbiObjs.Count -gt 0 -and -not (Test-Path $abiDest)) {
    Write-Host "    从 $($AbiObjs.Count) 个 .obj 组 libc++abi.lib"
    [void](New-StaticLibFromObjs -OutLib $abiDest -ObjFiles $AbiObjs)
}

if (Test-IsThinLib $destLib) {
    throw "验收失败: libc++.lib 为 thin，不可发布"
}

# --- 验收 __libcpp_verbose_abort 可解析 --------------------------------------
# 优先用 obj 文件判据（可靠）：libc++.lib 由包含 verbose_abort.obj 的完整 libc++
# source_set 组成，即含该符号。nm/dumpbin 仅作补充证据，不作为唯一硬门槛，避免
# Windows 上工具输出差异导致的假失败。
$verboseFromObjs = (Test-ObjsHaveVerboseAbort -Objs $LibcxxObjs) `
    -or (Test-ObjsHaveVerboseAbort -Objs $AbiObjs)
$verboseFromNm = (Test-ArchiveDefinesSymbol -Archive $destLib -Symbol "__libcpp_verbose_abort") `
    -or (Test-ArchiveDefinesSymbol -Archive $abiDest -Symbol "__libcpp_verbose_abort")

# libcxx_merged 只由 monolith 自身是否“定义”(非 U) 该符号决定，作为下游是否需
# 另链 libc++.lib 的元数据。实测 Windows 上 v8_monolith.lib 里 __libcpp_verbose_abort
# 仍是 U（引用），定义只在独立 libc++.lib → 应为 false（下游必须另链 libc++.lib）。
# 注意: 不能用“找到了 verbose_abort.obj”反推 merged=true —— 那只说明能组独立库，
# 不代表 monolith 已自含；早期因 nm 正则 mangling bug 曾错误据此置 true。
$LibcxxMerged = Test-ArchiveDefinesSymbol -Archive $Monolith -Symbol "__libcpp_verbose_abort"

if ($verboseFromObjs) {
    Write-Host "    验收通过: libc++ 目标含 verbose_abort.obj（__libcpp_verbose_abort 可解析）"
} elseif ($verboseFromNm) {
    Write-Host "    验收通过: nm/dumpbin 探到 __libcpp_verbose_abort"
} elseif ($LibcxxMerged) {
    Write-Host "    验收通过: __libcpp_verbose_abort 已并入 v8_monolith.lib"
} else {
    throw "验收失败: 未在 libc++.lib / libc++abi.lib / monolith 中找到 __libcpp_verbose_abort（下游无法链接）"
}

if ($LibcxxMerged) {
    Write-Host "==> libc++ 已并入 v8_monolith.lib (libcxx_merged=true)；仍附带独立 libc++.lib"
} else {
    Write-Host "==> libc++ 未并入 monolith (libcxx_merged=false)，下游须另链 libc++.lib"
}

if (-not (Test-Path (Join-Path $Prefix "libcxx\include\__config_site"))) {
    throw "验收失败: 缺少 libcxx/include/__config_site"
}
$monoOut = Join-Path $Prefix "lib\v8_monolith.lib"
if (Test-IsThinLib $monoOut) { throw "验收失败: v8_monolith.lib 为 thin，不可发布" }
$must = Join-Path $Prefix "lib\libc++.lib"
if (-not (Test-Path $must)) { throw "验收失败: 缺少 lib/libc++.lib" }
if (Test-IsThinLib $must) { throw "验收失败: lib/libc++.lib 为 thin，不可发布" }

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
libcxx_comment : 下游必须用包内 libcxx/include (+ libcxxabi/include) 编译；ABI=std::__Cr。务必另链 thick lib/libc++.lib（Windows 由 source_set .obj 组库）
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
  ${V8_ROOT}/lib/libc++.lib            # 必须：thick（由 source_set .obj 组库）
  ${V8_ROOT}/lib/libc++abi.lib         # 若包内存在

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
