@echo off
rem ============================================
rem  简单连点器 - 启动入口
rem  双击本文件即可运行，无需安装任何软件
rem ============================================
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "AutoClicker.ps1"
