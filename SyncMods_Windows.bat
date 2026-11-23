@echo off
chcp 65001 >nul
cd /d "%~dp0"
set RAW_BASE=https://raw.githubusercontent.com/PhenylPropion/PokemonServer-Modpack/main
if not exist "%~dp0SyncMods_Windows.ps1" (
  echo SyncMods_Windows.ps1 をGitHubから取得中...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%RAW_BASE%/SyncMods_Windows.ps1' -OutFile '%~dp0SyncMods_Windows.ps1'"
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SyncMods_Windows.ps1" -RawBaseUrl "%RAW_BASE%" %*
echo.
pause
