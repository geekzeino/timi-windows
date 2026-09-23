@echo off
rem Timi (Windows) - one-way rules/hooks/memory/skills refresh from the Linux host.
rem Contract: SHARE-CONTRACT.json (schema 1). One-way host -> guest, repeatable,
rem logged. /XO skips unchanged files, so a second run updates rather than duplicates.
rem Hook families are NOT carried as executables: per SHARE-CONTRACT.json every
rem live Linux hook family is dispositioned (host-session machinery with no guest
rem equivalent), so this script syncs rules, memory and skills only - and the
rem disposition list lives in the contract, not here.
rem Share: \\192.168.122.1\claude  (map-drives.cmd mounts it; see that file)
setlocal
set LOG=%LOCALAPPDATA%\Timi\share.log
set SHARE=\\192.168.122.1\claude

if not exist "%LOCALAPPDATA%\Timi" mkdir "%LOCALAPPDATA%\Timi" >nul 2>&1
echo [%date% %time%] refresh start >> "%LOG%"

if not exist "%SHARE%\" (
  echo Timi: share %SHARE% is not reachable - map-drives.cmd mounts it; run that first.
  echo [%date% %time%] FAIL share unreachable >> "%LOG%"
  exit /b 2
)

robocopy "%SHARE%\CLAUDE.md" "%USERPROFILE%\.claude\" CLAUDE.md /XO /NJH /NJS /NDL >> "%LOG%"
rem /MIR is only ever pointed at a NON-EMPTY source: a partial share sync must
rem fail loudly here instead of mirroring the guest's memory tree away.
set MEMSRC=%SHARE%\projects\-home-zeino\memory
if not exist "%MEMSRC%\*" (
  echo [%date% %time%] FAIL memory source %MEMSRC% missing or empty - /MIR skipped >> "%LOG%"
  echo Timi: memory source on the share is missing or empty - memory sync skipped.
  exit /b 3
)
robocopy "%MEMSRC%" "%USERPROFILE%\.claude\projects\-home-zeino\memory" /MIR /XO /NJH /NJS /NDL >> "%LOG%"
robocopy "%SHARE%\skills" "%USERPROFILE%\.claude\skills" /E /XO /NJH /NJS /NDL >> "%LOG%"

echo [%date% %time%] refresh done rc=%ERRORLEVEL% >> "%LOG%"
echo Timi: setup refreshed. Log: %LOG%
exit /b 0
