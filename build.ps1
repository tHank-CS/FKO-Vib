<#
    FKO-Vib 构建脚本（无需 Gradle）

    依赖：
      - Android SDK build-tools（aapt2 / d8 / apksigner / zipalign）
      - Android platform 的 android.jar（API 35+）
      - Xposed API jar（默认 libs/xposed-api.jar）
      - JDK 17+

    用法示例：
      .\build.ps1 -BuildTools "C:\Android\build-tools\36.0.0" `
                  -AndroidJar "C:\Android\platforms\android-36\android.jar"

    首次构建会自动生成 build/keystore 用于签名（仅本地调试用）。
#>
param(
    [Parameter(Mandatory = $true)][string]$BuildTools,
    [Parameter(Mandatory = $true)][string]$AndroidJar,
    [string]$XposedApi = "",
    [string]$OutDir = "dist",
    [string]$Keystore = "",
    [string]$KeystorePass = "android",
    [string]$KeyAlias = "fkovib"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($XposedApi)) {
    $XposedApi = Join-Path $root "libs\xposed-api.jar"
}

foreach ($p in @($BuildTools, (Join-Path $BuildTools "aapt2.exe"), $AndroidJar, $XposedApi)) {
    if (-not (Test-Path $p)) { throw "required path not found: $p" }
}

$jdkHome = $env:JAVA_HOME
if ([string]::IsNullOrWhiteSpace($jdkHome) -or -not (Test-Path (Join-Path $jdkHome "bin\javac.exe"))) {
    $jdkHome = "C:\Program Files\Java\jdk-17"
}
$javac = Join-Path $jdkHome "bin\javac.exe"
$jar = Join-Path $jdkHome "bin\jar.exe"
$keytool = Join-Path $jdkHome "bin\keytool.exe"
$env:JAVA_HOME = $jdkHome

$build = Join-Path $root "build"
$classes = Join-Path $build "classes"
$out = Join-Path $root $OutDir
New-Item -ItemType Directory -Force -Path $build, $classes, $out | Out-Null

Write-Host "[1/7] aapt2 compile resources"
$resZip = Join-Path $build "res.zip"
& (Join-Path $BuildTools "aapt2.exe") compile --dir (Join-Path $root "module\res") -o $resZip
if ($LASTEXITCODE -ne 0) { throw "aapt2 compile failed" }

Write-Host "[2/7] aapt2 link"
& (Join-Path $BuildTools "aapt2.exe") link `
    -o (Join-Path $build "base.apk") `
    -I $AndroidJar `
    --manifest (Join-Path $root "module\AndroidManifest.xml") `
    -A (Join-Path $root "module\assets") `
    -R $resZip `
    --min-sdk-version 35 --target-sdk-version 36
if ($LASTEXITCODE -ne 0) { throw "aapt2 failed" }

Write-Host "[3/7] javac"
& $javac -encoding UTF-8 -source 8 -target 8 `
    -bootclasspath $AndroidJar -classpath $XposedApi `
    -d $classes `
    (Join-Path $root "module\src\com\fko\vib\Hook.java")
if ($LASTEXITCODE -ne 0) { throw "javac failed" }

Write-Host "[4/7] d8"
$classFiles = Get-ChildItem (Join-Path $classes "com\fko\vib") -Filter *.class |
    ForEach-Object { $_.FullName }
& (Join-Path $BuildTools "d8.bat") --lib $AndroidJar --min-api 35 `
    --output $build @classFiles
if ($LASTEXITCODE -ne 0) { throw "d8 failed" }

Write-Host "[5/7] package dex"
& $jar --update --file (Join-Path $build "base.apk") -C $build classes.dex
if ($LASTEXITCODE -ne 0) { throw "jar update failed" }

Write-Host "[6/7] zipalign"
& (Join-Path $BuildTools "zipalign.exe") -f -p 4 `
    (Join-Path $build "base.apk") (Join-Path $build "aligned.apk")
if ($LASTEXITCODE -ne 0) { throw "zipalign failed" }

Write-Host "[7/7] sign"
if ([string]::IsNullOrWhiteSpace($Keystore)) {
    $Keystore = Join-Path $root "keystore\fkovib.jks"
    $keystoreDir = Split-Path -Parent $Keystore
    New-Item -ItemType Directory -Force -Path $keystoreDir | Out-Null
    if (-not (Test-Path $Keystore)) {
        & $keytool -genkeypair -keystore $Keystore -storepass $KeystorePass `
            -keypass $KeystorePass -alias $KeyAlias -keyalg RSA -keysize 2048 `
            -validity 10000 -dname "CN=FKO-Vib,O=Local,C=CN" -noprompt | Out-Null
    }
}
$apk = Join-Path $out "FKO-Vib-1.0.0.apk"
& (Join-Path $BuildTools "apksigner.bat") sign `
    --ks $Keystore --ks-pass "pass:$KeystorePass" --key-pass "pass:$KeystorePass" `
    --out $apk (Join-Path $build "aligned.apk")
if ($LASTEXITCODE -ne 0) { throw "apksigner failed" }

Write-Host "done: $apk"
Get-Item $apk | Select-Object Name, Length
