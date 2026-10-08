@echo off
chcp 65001 >nul
title 迁移剩余 AI 工具目录到 D 盘
echo ========================================================
echo   C Drive Savior - 迁移剩余 AI 工具目录 (Junction 软链接)
echo ========================================================
echo.
echo 注意：请在运行此脚本前，彻底退出以下软件（可在任务管理器检查）：
echo   1. Codex (包括后台主机进程)
echo   2. Claude 桌面端
echo   3. ChatGPT 桌面端
echo.
echo 包含待迁移项（预计再释放约 12 GB）：
echo   - C:\Users\华为\.codex (7.62 GB)
echo   - C:\Users\华为\.cache\codex-runtimes (2.18 GB)
echo   - C:\Users\华为\.claude (1.15 GB)
echo   - C:\Users\华为\AppData\Local\OpenAI (1.09 GB)
echo.
set /p confirm=已退出上述软件并确认开始迁移吗？(Y/N): 
if /i not "%confirm%"=="Y" (
    echo 已取消操作。
    pause
    exit /b
)

echo.
echo 正在执行安全迁移与软链接建立...
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\华为\.gemini\antigravity\scratch\C-Drive-Savior\scripts\migrate_to_d_with_junction.ps1"

echo.
echo 处理完成！最新磁盘状态：
powershell -NoProfile -Command "Get-PSDrive C,D | Select-Object Name, @{N='FreeGB';E={[math]::Round($_.Free/1GB,2)}} | Format-Table -AutoSize"
pause
