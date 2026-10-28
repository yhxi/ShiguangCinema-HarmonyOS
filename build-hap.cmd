@echo off
setlocal

set CLI_HOME=E:\Development\command-line-tools
set PROJECT_HOME=%~dp0

if not exist "%CLI_HOME%\bin\hvigorw.bat" (
  echo [ERROR] hvigorw not found at %CLI_HOME%\bin\hvigorw.bat
  exit /b 1
)

set PATH=%CLI_HOME%\bin;%PATH%
set DEVECO_SDK_HOME=%CLI_HOME%\sdk
set NODE_HOME=%CLI_HOME%\tool\node
set PATH=%NODE_HOME%;%PATH%

cd /d "%PROJECT_HOME%"

set BUILD_MODE=%1
if "%BUILD_MODE%"=="" set BUILD_MODE=debug

echo [INFO] building...
call hvigorw.bat --mode module -p module=entry@default -p product=default -p buildMode=%BUILD_MODE% --no-daemon assembleHap
if errorlevel 1 (
  echo [ERROR] build failed
  exit /b 1
)

echo.
echo [OK] HAP output:
dir /s /b entry\build\*.hap 2>nul
endlocal
