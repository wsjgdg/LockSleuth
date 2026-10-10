@echo off
rem =====================================================
rem  LockSleuth 单元测试门禁（Windows / MSVC）
rem  用法：在 “x64 Native Tools Command Prompt for VS” 中运行
rem  等价于 POSIX 上的 make test / tests/verify.sh
rem =====================================================
setlocal
where cl >nul 2>nul
if %errorlevel% neq 0 (
    echo [错误] 未找到 cl(MSVC)。请在 “x64 Native Tools Command Prompt for VS” 中运行本脚本。
    exit /b 1
)
if not exist build mkdir build

echo [1/2] 编译并运行 unit_test（rules + jsonutil）...
cl /nologo /utf-8 /W3 /D_CRT_SECURE_NO_WARNINGS /I src src\rules.c src\jsonutil.c tests\unit_test.c /Fe:build\unit_test.exe
if %errorlevel% neq 0 exit /b 1
build\unit_test.exe
if %errorlevel% neq 0 exit /b 1

echo [2/2] 编译并运行 unit_history（history + jsonutil）...
cl /nologo /utf-8 /W3 /D_CRT_SECURE_NO_WARNINGS /I src src\history.c src\jsonutil.c tests\unit_history.c /Fe:build\unit_history.exe
if %errorlevel% neq 0 exit /b 1
build\unit_history.exe
if %errorlevel% neq 0 exit /b 1

echo.
echo [OK] 全部单元测试通过
exit /b 0
