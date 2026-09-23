@echo off
rem Host share credential placeholder (optional local VM host setup)
rem cmdkey /add:192.168.122.1 /user:zeino >nul 2>&1
net use H: \\192.168.122.1\HDD20TB /persistent:yes >nul 2>&1
net use Y: \\192.168.122.1\HDD8 /persistent:yes >nul 2>&1
net use > "%USERPROFILE%\Documents\.mapped.txt" 2>&1
