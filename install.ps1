$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 1. Ensure agy is installed
if (-not (Get-Command agy -ErrorAction SilentlyContinue) -and -not (Test-Path "$env:LOCALAPPDATA\agy\bin\agy.exe")) {
    Write-Host "Installing Antigravity CLI (agy)..." -ForegroundColor Cyan
    try {
        Invoke-RestMethod https://antigravity.google/cli/install.ps1 | Invoke-Expression
    } catch {
        Write-Warning "Could not install agy: $($_.Exception.Message)"
    }
}

# 2. Download and unpack Timi
$zipPath = "$env:TEMP\timi.zip"
$destDir = "$HOME\Timi"
$url = "https://github.com/geekzeino/timi-windows/archive/refs/heads/main.zip"

Write-Host "Downloading Timi..." -ForegroundColor Cyan
if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
    & curl.exe -sL $url -o $zipPath
} else {
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
}

Write-Host "Extracting Timi..." -ForegroundColor Cyan
$extractTmp = "$env:TEMP\timi_unzip"
Remove-Item -Recurse -Force $extractTmp -ErrorAction SilentlyContinue
Expand-Archive -Path $zipPath -DestinationPath $extractTmp -Force
Remove-Item -Recurse -Force $destDir -ErrorAction SilentlyContinue
Move-Item "$extractTmp\timi-windows-main" $destDir -Force
Remove-Item $zipPath, $extractTmp -Recurse -Force -ErrorAction SilentlyContinue

# 3. Run installer
Write-Host "Launching Timi setup..." -ForegroundColor Cyan
& powershell.exe -ExecutionPolicy Bypass -File "$destDir\Install-Timi.ps1"
