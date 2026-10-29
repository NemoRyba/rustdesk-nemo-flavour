@echo off
start "TBFDesk debug" powershell -NoExit -Command "$env:RUST_LOG='debug'; Start-Process 'C:\Program Files\TBFDesk\TBFDesk.exe' -NoNewWindow -Wait"
