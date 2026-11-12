@echo off
setlocal
echo Installing Voice for this Windows user. Finish recordings and close Voice first.
powershell.exe -NoProfile -File "%~dp0install.ps1" -DesktopShortcut
if errorlevel 1 (
  echo.
  echo Installation did not complete. Read the message above.
  echo If Windows blocks scripts, you can use Voice.exe directly from this extracted folder.
  pause
  exit /b 1
)
endlocal
