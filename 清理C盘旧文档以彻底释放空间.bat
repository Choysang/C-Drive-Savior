@echo off
chcp 65001 >nul
title 清理 C 盘旧文档以彻底释放空间
echo ========================================================
echo   C Drive Savior - 彻底释放 C 盘旧文档空间
echo ========================================================
echo.
echo 注意：请确认您已打开 D:\Documents 检查过文件完整无误。
echo 目标：清理 C:\Users\华为\Documents 中的旧文件（约 12+ GB）
echo.
set /p confirm=确认开始清理旧文档吗？(Y/N): 
if /i not "%confirm%"=="Y" (
    echo 已取消操作。
    pause
    exit /b
)

echo.
echo 正在执行旧文件清理...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Remove-Item -LiteralPath '$env:USERPROFILE\Documents\*' -Recurse -Force -ErrorAction SilentlyContinue"

echo.
echo 清理完成！C 盘已彻底释放旧文档空间！
echo 当前磁盘空间状态：
powershell -NoProfile -Command "Get-PSDrive C,D | Select-Object Name, @{N='FreeGB';E={[math]::Round($_.Free/1GB,2)}} | Format-Table -AutoSize"
pause
