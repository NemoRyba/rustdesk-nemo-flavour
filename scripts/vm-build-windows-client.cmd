@echo off
REM Release build of the TBFDesk Windows client on the Win11 test VM (vm/scripts/vmctl.sh):
REM regenerate the inline UI, cargo build --features inline,hwcodec,vram, pack the
REM self-extracting installer -> C:\src\dist\tbfdesk-<VER>-x64-install.exe. Log: C:\src\build-<VER>.log.
REM Expects the VM toolchain (C:\build\tools: vcpkg, llvm-15.0.6, nasm; VS 2022 Build Tools;
REM Python 3.12 + brotli) and the client tree at C:\src\rustdesk-client-nemo.
REM Copy to C:\src\build<ver>.cmd, set VER below, and run it over ONE held-open SSH session:
REM     vmctl.sh ssh "cmd /c C:\src\build1419.cmd"        (~4 min incremental)
REM VER is hardcoded on purpose: taking it as %~1 made every redirect below fail with
REM "The filename, directory name, or volume label syntax is incorrect" (cause not found).
REM CRLF line endings are required (cmd misreads labels in an LF-only batch file).
set "VER=1.4.19"
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
set "VCPKG_ROOT=C:\build\tools\vcpkg"
set "LIBCLANG_PATH=C:\build\tools\llvm-15.0.6\bin"
set "PATH=C:\Program Files\Python312;%PATH%;C:\build\tools\nasm;C:\Program Files\Git\cmd;%USERPROFILE%\.cargo\bin"
cd /d C:\src\rustdesk-client-nemo
set "LOG=C:\src\build-%VER%.log"
echo === start %DATE% %TIME% === > "%LOG%"
python res\inline-sciter.py >> "%LOG%" 2>&1 || goto :fail
echo --- inline.rs regenerated >> "%LOG%"
cargo build --release --features inline,hwcodec,vram >> "%LOG%" 2>&1 || goto :fail
echo --- client built %TIME% >> "%LOG%"
copy /Y target\release\rustdesk.exe Release\rustdesk.exe >> "%LOG%" || goto :fail
copy /Y target\release\service.exe Release\service.exe >> "%LOG%" || goto :fail
if exist target\release\rustdesk-portable-packer.exe del /F /Q target\release\rustdesk-portable-packer.exe
python libs\portable\generate.py -f Release -o libs\portable -e rustdesk.exe >> "%LOG%" 2>&1
if not exist target\release\rustdesk-portable-packer.exe goto :fail
copy /Y target\release\rustdesk-portable-packer.exe C:\src\dist\tbfdesk-%VER%-x64-install.exe >> "%LOG%" || goto :fail
echo === DONE OK %DATE% %TIME% === >> "%LOG%"
exit /b 0
:fail
echo === FAILED errorlevel=%ERRORLEVEL% %DATE% %TIME% === >> "%LOG%"
exit /b 1
