<#
=============================================================================
 V8 构建脚本 (Windows, MSVC / clang-cl)

 用法:
   pwsh v8/scripts/build_windows.ps1 -Target windows-x64-msvc

 自包含流程 (与 libavif 的 build_windows.ps1 风格一致):
   depot_tools -> gclient sync -> checkout 版本 -> gn gen -> ninja v8_monolith
   -> 收集 include + v8_monolith.lib -> 打包为 zip

 依赖 (由 CI 预先安装): Visual Studio 2022 (含 C++ 工具链), git, Python。
 使用 runner 自带 VS: 设置 DEPOT_TOOLS_WIN_TOOLCHAIN=0。

 产物: v8\out\<Target>\{include, lib\v8_monolith.lib}
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
$EnablePtrCmp = Get-Cfg "V8_ENABLE_POINTER_COMPRESSION" "true"

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
$argsContent += "v8_enable_pointer_compression = $EnablePtrCmp"
$argsContent += ""
$argsContent += "# --- 固定参数 (产出单一静态库) ---"
$argsContent += "v8_monolithic = true"
$argsContent += "is_component_build = false"
$argsContent += "v8_use_external_startup_data = false"
$argsContent += "treat_warnings_as_errors = false"
# 用系统/工具链 libc++ (use_custom_libcxx=false) 时 V8 sandbox 需要 libc++ 加固，冲突，
# 嵌入场景关闭 sandbox；与指针压缩相互独立。
$argsContent += "v8_enable_sandbox = false"
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

# --- 6) 打包为 zip -----------------------------------------------------------
$Dist    = Join-Path $LibRoot "dist"
$PkgName = "$PackageName-$PkgVersion-$Target"
$Stage   = Join-Path $Dist $PkgName
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "lib") | Out-Null

Copy-Item -Recurse (Join-Path $Prefix "include") (Join-Path $Stage "include")
Copy-Item (Join-Path $Prefix "lib\v8_monolith.lib") (Join-Path $Stage "lib\v8_monolith.lib")

# 许可证
foreach ($f in @("LICENSE", "LICENSE.txt", "COPYING")) {
    $p = Join-Path $V8Src $f
    if (Test-Path $p) { Copy-Item $p (Join-Path $Stage "LICENSE-v8"); break }
}

$BuildInfo = @"
Package     : $PkgName
Target      : $Target
v8          : $V8Version
i18n        : $EnableI18n
webassembly : $EnableWasm
ptr_compr   : $EnablePtrCmp
symbol_level: $SymbolLevel
Linkage     : static (v8_monolith)
Built (UTC) : $((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss"))
Built by    : GitHub Actions (build-static-libs)
"@
Set-Content -Path (Join-Path $Stage "BUILD_INFO.txt") -Value $BuildInfo -Encoding UTF8

$Zip = Join-Path $Dist "$PkgName.zip"
if (Test-Path $Zip) { Remove-Item -Force $Zip }
Compress-Archive -Path $Stage -DestinationPath $Zip
Remove-Item -Recurse -Force $Stage

Write-Host "==> 打包完成: $Zip"
Get-ChildItem $Zip | Format-List
