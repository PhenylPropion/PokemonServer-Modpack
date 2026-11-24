@echo off
chcp 65001 >nul
cd /d "%~dp0"
set RAW_BASE=https://raw.githubusercontent.com/PhenylPropion/PokemonServer-Modpack/season2
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; try { Invoke-WebRequest -UseBasicParsing -Uri '%RAW_BASE%/SyncMods_Windows.ps1' -OutFile '%~dp0SyncMods_Windows.ps1.tmp' -ErrorAction Stop; Move-Item -Force '%~dp0SyncMods_Windows.ps1.tmp' '%~dp0SyncMods_Windows.ps1' } catch { Remove-Item -Force -ErrorAction SilentlyContinue '%~dp0SyncMods_Windows.ps1.tmp' }"
if not exist "%~dp0SyncMods_Windows.ps1" (
  echo [エラー] SyncMods_Windows.ps1 をGitHubから取得できませんでした。
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SyncMods_Windows.ps1" -RawBaseUrl "%RAW_BASE%" %*
echo.
pause
