@echo off

setlocal
set PROJECT_HOME=%~dp0
set SIGNTOOL=E:\Development\command-line-tools\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar
set KS=%PROJECT_HOME%sign\shiguang-debug.p12
rem 密钥库密码从环境变量读取，不写进仓库：
rem   set SIGN_PWD=你的密钥库密码
if "%SIGN_PWD%"=="" (
  echo [ERROR] SIGN_PWD not set
  echo         run: set SIGN_PWD=your-keystore-password
  pause & exit /b 1
)
set KS_PWD=%SIGN_PWD%
set ALIAS=shiguang
set ALIAS_PWD=%SIGN_PWD%
set CERT=%PROJECT_HOME%sign\shiguang-debug.cer
set PROFILE=%PROJECT_HOME%sign\shiguang-debug.p7b
set OUT=%PROJECT_HOME%dist\shiguang-1.0.2-debug-signed.hap
set IN=%PROJECT_HOME%entry\build\default\outputs\default\entry-default-unsigned.hap

if not exist "%CERT%" (
  echo [ERROR] missing %CERT%
  echo         put the AGC debug certificate into sign\ as shiguang-debug.cer
  pause & exit /b 1
)
if not exist "%PROFILE%" (
  echo [ERROR] missing %PROFILE%
  echo         put the AGC debug profile into sign\ as shiguang-debug.p7b
  pause & exit /b 1
)

java -jar "%SIGNTOOL%" sign-app ^
  -keyAlias "%ALIAS%" -keyPwd "%ALIAS_PWD%" ^
  -appCertFile "%CERT%" -profileFile "%PROFILE%" ^
  -inFile "%IN%" -outFile "%OUT%" ^
  -keystoreFile "%KS%" -keystorePwd "%KS_PWD%"

if errorlevel 1 (
  echo [ERROR] signing failed
  pause & exit /b 1
)

echo.
echo [OK] signed hap: %OUT%
echo      install:    hdc install "%OUT%"
pause
endlocal










