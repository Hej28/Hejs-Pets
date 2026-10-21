$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
python -m PyInstaller --noconfirm --clean --windowed --onedir --name HejsPets --icon assets/AppIcon.ico --add-data 'assets;assets' --collect-data cv2 --collect-all pillow_heif --copy-metadata PySide6 --copy-metadata PySide6_Essentials --copy-metadata shiboken6 --copy-metadata Pillow --copy-metadata pillow-heif --copy-metadata numpy --copy-metadata opencv-python-headless --exclude-module PySide6.QtWebEngineCore --exclude-module PySide6.QtWebEngineWidgets run.py
if ($LASTEXITCODE -ne 0) { throw 'PyInstaller failed' }
New-Item -ItemType Directory -Force release | Out-Null
Copy-Item ..\LICENSE dist\HejsPets\LICENSE.txt
Copy-Item README.md dist\HejsPets\README.md
Copy-Item THIRD_PARTY.md dist\HejsPets\THIRD_PARTY.md
Compress-Archive -Path dist\HejsPets -DestinationPath release\HejsPets-4.1.0-Windows-Portable.zip -Force
$iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if ($null -eq $iscc) { $compiler = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" } else { $compiler = $iscc.Source }
if (-not (Test-Path $compiler)) { throw 'Install Inno Setup 6 to build the installer.' }
& $compiler installer.iss
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed' }
Get-ChildItem release\* | Get-FileHash -Algorithm SHA256 | ForEach-Object { "$($_.Hash.ToLower())  $(Split-Path $_.Path -Leaf)" } | Set-Content release\SHA256SUMS.txt -Encoding ascii
