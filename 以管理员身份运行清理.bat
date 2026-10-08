@echo off
chcp 65001 >nul
title C Drive Savior - 管理员清理
echo ========================================================
echo   C Drive Savior / C盘拯救者 - 管理员专项清理
echo   会话 ID: python-8708ea03a93c
echo ========================================================
echo.
echo 正在执行管理员级清理 (wer-system, temp-windows, wu-cache, minidump)...
powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'C:\Users\华为\.gemini\antigravity\scratch\C-Drive-Savior\scripts\clean.ps1' -Execute -SessionId 'python-8708ea03a93c' -SessionRoot '$env:USERPROFILE\c-drive-savior\sessions' -Include @('wer-system', 'temp-windows', 'wu-cache', 'minidump')"

echo.
echo 正在更新会话报告...
powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'C:\Users\华为\.gemini\antigravity\scratch\C-Drive-Savior\scripts\report.ps1' -SessionId 'python-8708ea03a93c' -SessionRoot '$env:USERPROFILE\c-drive-savior\sessions' -OpenReport"

echo.
echo 清理完成！已在浏览器中打开最新报告。
pause
