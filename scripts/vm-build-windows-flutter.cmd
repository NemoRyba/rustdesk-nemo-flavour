@echo off
REM Release build of the TBFDesk Windows client with the FLUTTER UI on the Win11 test VM
REM (vm/scripts/vmctl.sh): cargo build --lib (flutter,hwcodec,vram), flutter build windows,
REM pack the self-extracting installer -> C:\src\dist\tbfdesk-flutter-<VER>-x64-install.exe.
REM Log: C:\src\build-flutter-<VER>.log. The Sciter installer is vm-build-windows-client.cmd.
REM The packer (libs\portable\generate.py) sees data\flutter_assets and writes
REM tbfdesk_ui = "flutter" into the installer: the management server publishes it only on
REM the "Windows (x64) Flutter" update channel.
REM Needs the VM toolchain of vm-build-windows-client.cmd plus Flutter at C:\build\tools\flutter
REM and the 4 generated bridge files (whenever src\flutter_ffi.rs changed).
REM Copy to C:\src\buildfl<ver>.cmd, set VER below (= Cargo.toml version), run over ONE
REM held-open SSH session:   vmctl.sh ssh "cmd /c C:\src\buildfl1419.cmd"
REM CRLF line endings are required.
set "VER=1.4.19"
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
set "VCPKG_ROOT=C:\build\tools\vcpkg"
set "LIBCLANG_PATH=C:\build\tools\llvm-15.0.6\bin"
set "PATH=C:\build\tools\flutter\bin;C:\Program Files\Python312;%PATH%;C:\build\tools\nasm;C:\Program Files\Git\cmd;%USERPROFILE%\.cargo\bin"
cd /d C:\src\rustdesk-client-nemo
set "LOG=C:\src\build-flutter-%VER%.log"
set "REL=flutter\build\windows\x64\runner\Release"
echo === start %DATE% %TIME% === > "%LOG%"
git log --oneline -1 >> "%LOG%" 2>&1
cargo build --release --lib --features flutter,hwcodec,vram >> "%LOG%" 2>&1 || goto :fail
echo --- rust lib built %TIME% >> "%LOG%"
cd flutter
call flutter pub get >> "%LOG%" 2>&1 || goto :fail
call flutter build windows --release >> "%LOG%" 2>&1 || goto :fail
cd ..
echo --- flutter built %TIME% >> "%LOG%"
if exist target\release\deps\dylib_virtual_display.dll copy /Y target\release\deps\dylib_virtual_display.dll %REL%\ >> "%LOG%"
if exist target\release\rustdesk-portable-packer.exe del /F /Q target\release\rustdesk-portable-packer.exe
python libs\portable\generate.py -f %REL% -o libs\portable -e rustdesk.exe >> "%LOG%" 2>&1
if not exist target\release\rustdesk-portable-packer.exe goto :fail
if not exist C:\src\dist md C:\src\dist
copy /Y target\release\rustdesk-portable-packer.exe C:\src\dist\tbfdesk-flutter-%VER%-x64-install.exe >> "%LOG%" || goto :fail
echo === DONE OK %DATE% %TIME% === >> "%LOG%"
exit /b 0
:fail
echo === FAILED errorlevel=%ERRORLEVEL% %DATE% %TIME% === >> "%LOG%"
exit /b 1
