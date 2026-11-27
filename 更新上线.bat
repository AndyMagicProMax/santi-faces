@echo off
chcp 65001 >nul
cd /d "%~dp0"
git add -A
git commit -m "更新 %date% %time%"
git push
echo.
echo 推送完成，等 1 分钟刷新网页即可看到新版。
pause