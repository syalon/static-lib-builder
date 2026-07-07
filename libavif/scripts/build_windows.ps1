<#
=============================================================================
 Windows 构建脚本 (MSVC)

 用法:
   pwsh scripts/build_windows.ps1 -Target windows-x64-msvc

 产出 MSVC ABI 的静态库 (dav1d.lib / avif.lib)。
 MinGW 版本由 scripts/build_unix.sh windows-x64-mingw 在 Linux 上交叉编译。

 依赖 (由 CI 预先安装):
   Visual Studio (MSVC) + 已激活的开发者环境, meson, ninja, nasm, cmake, git
   建议在 "Developer Command Prompt / VS Dev Shell" 环境下运行，
   使 cl.exe / lib.exe 在 PATH 中。

 产物安装到: <repo>\out\<Target>\{include,lib}
=============================================================================
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Target = "windows-x64-msvc"
)

$ErrorActionPreference = "Stop"

# --- 解析仓库根目录并加载 versions.env --------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir "..")).Path

$Versions = @{}
Get-Content (Join-Path $RepoRoot "config.env") | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $kv = $line.Split("=", 2)
        $Versions[$kv[0].Trim()] = $kv[1].Trim()
    }
}

$LibavifVersion = $Versions["LIBAVIF_VERSION"]
$Dav1dVersion   = $Versions["DAV1D_VERSION"]
$EnableLibyuv   = if ($Versions["ENABLE_LIBYUV"]) { $Versions["ENABLE_LIBYUV"] } else { "OFF" }

$Work   = Join-Path $RepoRoot "work\$Target"
$Prefix = Join-Path $RepoRoot "out\$Target"
$Jobs   = [Environment]::ProcessorCount

if (Test-Path $Prefix) { Remove-Item -Recurse -Force $Prefix }
New-Item -ItemType Directory -Force -Path $Work, $Prefix | Out-Null

Write-Host "==> Target   : $Target"
Write-Host "==> libavif  : $LibavifVersion"
Write-Host "==> dav1d    : $Dav1dVersion"
Write-Host "==> Prefix   : $Prefix"

function Invoke-Checked {
    param([scriptblock]$Block)
    & $Block
    if ($LASTEXITCODE -ne 0) { throw "命令失败，退出码 $LASTEXITCODE" }
}

# =============================================================================
# 1) 获取源码
# =============================================================================
if (-not (Test-Path (Join-Path $Work "dav1d\.git"))) {
    Invoke-Checked { git clone --depth 1 --branch $Dav1dVersion `
        https://code.videolan.org/videolan/dav1d.git (Join-Path $Work "dav1d") }
}
if (-not (Test-Path (Join-Path $Work "libavif\.git"))) {
    Invoke-Checked { git clone --depth 1 --branch $LibavifVersion `
        https://github.com/AOMediaCodec/libavif.git (Join-Path $Work "libavif") }
}

# =============================================================================
# 2) 构建 dav1d (Meson + Ninja, MSVC, 静态)
# =============================================================================
$Dav1dSrc   = Join-Path $Work "dav1d"
$Dav1dBuild = Join-Path $Dav1dSrc "build-$Target"
if (Test-Path $Dav1dBuild) { Remove-Item -Recurse -Force $Dav1dBuild }

Invoke-Checked { meson setup $Dav1dBuild $Dav1dSrc `
    --prefix="$Prefix" `
    --libdir=lib `
    --buildtype=release `
    --default-library=static `
    -Denable_tools=false `
    -Denable_tests=false }
Invoke-Checked { meson compile -C $Dav1dBuild -j $Jobs }
Invoke-Checked { meson install -C $Dav1dBuild }

# meson + MSVC 生成的 dav1d 静态库通常命名为 libdav1d.a (gcc 风格)，
# 规范化出一份 dav1d.lib，使以下三处都能解析到该库：
#   - 下游 MSVC 链接时 dav1d.pc 里的 -ldav1d
#   - libavif 的 -DDAV1D_LIBRARY
#   - 后面打包时的 *.lib 过滤器 (否则会漏掉 dav1d 静态库)
$LibDir   = Join-Path $Prefix "lib"
$Dav1dLib = Join-Path $LibDir "dav1d.lib"
if (-not (Test-Path $Dav1dLib)) {
    $Dav1dCand = Get-ChildItem $LibDir -File |
        Where-Object { $_.Name -match '^(lib)?dav1d\.(a|lib)$' } |
        Select-Object -First 1
    if (-not $Dav1dCand) {
        throw "未找到 dav1d 静态库 (期望 libdav1d.a 或 dav1d.lib) 于 $LibDir"
    }
    Copy-Item $Dav1dCand.FullName $Dav1dLib
    Write-Host "==> 规范化 dav1d 静态库: $($Dav1dCand.Name) -> dav1d.lib"
}

# =============================================================================
# 3) 构建 libavif (CMake, MSVC x64, 静态, dav1d=SYSTEM)
# =============================================================================
$AvifSrc   = Join-Path $Work "libavif"
$AvifBuild = Join-Path $AvifSrc "build-$Target"
if (Test-Path $AvifBuild) { Remove-Item -Recurse -Force $AvifBuild }

$env:PKG_CONFIG_PATH = Join-Path $Prefix "lib\pkgconfig"

# 使用 Ninja generator + 命令行 MSVC (cl.exe)，与 dav1d 保持同一套工具链。
# 避免 "Visual Studio 17 2022" generator 在 runner 上通过 vswhere
# 找不到 VS 实例而失败 (CI 已用 ilammy/msvc-dev-cmd 激活了 MSVC 环境)。
Invoke-Checked { cmake -S $AvifSrc -B $AvifBuild `
    -G "Ninja" `
    -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_C_COMPILER=cl `
    -DCMAKE_CXX_COMPILER=cl `
    -DBUILD_SHARED_LIBS=OFF `
    -DAVIF_CODEC_DAV1D=SYSTEM `
    -DAVIF_LIBYUV="$EnableLibyuv" `
    -DAVIF_BUILD_APPS=OFF `
    -DAVIF_BUILD_TESTS=OFF `
    -DAVIF_BUILD_EXAMPLES=OFF `
    -DCMAKE_INSTALL_PREFIX="$Prefix" `
    -DCMAKE_INSTALL_LIBDIR=lib `
    -DCMAKE_PREFIX_PATH="$Prefix" `
    -DDAV1D_INCLUDE_DIR="$(Join-Path $Prefix 'include')" `
    -DDAV1D_LIBRARY="$(Join-Path $Prefix 'lib\dav1d.lib')" }

Invoke-Checked { cmake --build $AvifBuild --parallel $Jobs }
Invoke-Checked { cmake --install $AvifBuild }

Write-Host "==> 完成: 产物位于 $Prefix"
Get-ChildItem -Recurse $Prefix | Select-Object FullName

# =============================================================================
# 4) 打包为 zip (与 Unix 侧 package.sh 结构保持一致)
# =============================================================================
$PkgVersion = if ($Versions["PACKAGE_VERSION"]) { $Versions["PACKAGE_VERSION"] } else { $LibavifVersion }
$PkgBase = if ($Versions["PACKAGE_NAME"]) { $Versions["PACKAGE_NAME"] } else { "libavif-dav1d" }
$Dist    = Join-Path $RepoRoot "dist"
$PkgName = "$PkgBase-$PkgVersion-$Target"
$Stage   = Join-Path $Dist $PkgName

if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "lib") | Out-Null

Copy-Item -Recurse (Join-Path $Prefix "include") (Join-Path $Stage "include")
Get-ChildItem (Join-Path $Prefix "lib") -Filter *.lib -File |
    ForEach-Object { Copy-Item $_.FullName (Join-Path $Stage "lib") }
$PkgConfig = Join-Path $Prefix "lib\pkgconfig"
if (Test-Path $PkgConfig) {
    Copy-Item -Recurse $PkgConfig (Join-Path $Stage "lib\pkgconfig")
}

# 校验两个静态库都已打包，避免再次静默遗漏 dav1d.lib
foreach ($required in @("avif.lib", "dav1d.lib")) {
    if (-not (Test-Path (Join-Path $Stage "lib\$required"))) {
        throw "打包缺少必需的静态库: $required"
    }
}

function Copy-License {
    param([string]$Src, [string]$Name)
    foreach ($f in @("LICENSE", "LICENSE.txt", "COPYING", "COPYING.txt")) {
        $p = Join-Path $Src $f
        if (Test-Path $p) { Copy-Item $p (Join-Path $Stage "LICENSE-$Name"); return }
    }
}
Copy-License (Join-Path $Work "libavif") "libavif"
Copy-License (Join-Path $Work "dav1d") "dav1d"

$BuildInfo = @"
Package     : $PkgName
Target      : $Target
libavif     : $LibavifVersion
dav1d       : $Dav1dVersion
libyuv      : $EnableLibyuv
Codec       : dav1d (decode only)
Linkage     : static
Built (UTC) : $((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss"))
Built by    : build-libavif-libdav1d GitHub Actions
"@
Set-Content -Path (Join-Path $Stage "BUILD_INFO.txt") -Value $BuildInfo -Encoding UTF8

$Zip = Join-Path $Dist "$PkgName.zip"
if (Test-Path $Zip) { Remove-Item -Force $Zip }
Compress-Archive -Path $Stage -DestinationPath $Zip
Remove-Item -Recurse -Force $Stage

Write-Host "==> 打包完成: $Zip"
