@echo off
rem ------------------------------------------------------------------
rem Desktop Clock launcher
rem Starts DesktopClock.ps1 from the same folder as this file, without
rem a console window. Keep both files together in one folder.
rem
rem   DesktopClock.bat          normal start (hidden)
rem   DesktopClock.bat debug    visible start that shows any error
rem ------------------------------------------------------------------

setlocal
set "DC_SCRIPT=%~dp0DesktopClock.ps1"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "CONHOST=%SystemRoot%\System32\conhost.exe"

if not exist "%DC_SCRIPT%" goto missing
if /i "%~1"=="debug" goto debug

rem --- Pre-launch checks (read-only). A hidden start cannot show errors,
rem --- so the common blockers are detected and explained here first.
"%PS%" -NoProfile -NonInteractive -Command "$p = $env:DC_SCRIPT; if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { exit 3 }; $pol = [string](Get-ExecutionPolicy); if ($pol -eq 'Restricted' -or $pol -eq 'AllSigned') { exit 4 }; $marked = Get-Item -LiteralPath $p -Stream Zone.Identifier -ErrorAction SilentlyContinue; if ($marked -and ($pol -eq 'RemoteSigned' -or $pol -eq 'Unrestricted')) { exit 5 }; exit 0"
if errorlevel 5 goto blocked
if errorlevel 4 goto policy
if errorlevel 3 goto language

:launch
if not exist "%CONHOST%" goto plain
start "" "%CONHOST%" --headless "%PS%" -NoProfile -WindowStyle Hidden -File "%DC_SCRIPT%"
goto end

:plain
start "" "%PS%" -NoProfile -WindowStyle Hidden -File "%DC_SCRIPT%"
goto end

:blocked
echo.
echo  Windows has marked DesktopClock.ps1 as downloaded from another
echo  computer (Teams, e-mail, OneDrive share or zip), so PowerShell's
echo  execution policy will not run it.
echo.
echo  If you trust this file, it can be unblocked. This is the same as
echo  right-click DesktopClock.ps1 ^> Properties ^> Unblock.
echo.
choice /c YN /m " Unblock DesktopClock.ps1 now"
if errorlevel 2 goto end
"%PS%" -NoProfile -NonInteractive -Command "Unblock-File -LiteralPath $env:DC_SCRIPT"
goto launch

:policy
echo.
echo  This computer's PowerShell execution policy does not allow this
echo  script to run (policy: Restricted or AllSigned).
echo.
echo  Current settings (the effective one is the first that is not Undefined):
"%PS%" -NoProfile -NonInteractive -Command "Get-ExecutionPolicy -List | Format-Table -AutoSize | Out-String"
echo  - MachinePolicy or UserPolicy set: enforced by your organization.
echo    Ask IT to approve or sign the script.
echo  - Everything Undefined: Windows' default applies. If your IT rules
echo    allow it, the per-user setting RemoteSigned can be chosen
echo    (no admin rights needed). Otherwise ask IT.
echo.
echo  Do not try to bypass the policy.
echo.
pause
goto end

:language
echo.
echo  PowerShell runs in Constrained Language mode on this computer
echo  (set by your organization), which this widget cannot use.
echo  Please ask IT whether the script can be approved.
echo.
pause
goto end

:debug
echo Starting visibly so that any error is shown...
"%PS%" -NoProfile -NoExit -File "%DC_SCRIPT%"
goto end

:missing
echo.
echo  DesktopClock.ps1 was not found in this folder:
echo  "%~dp0"
echo  Keep DesktopClock.bat and DesktopClock.ps1 together in one folder.
echo.
pause

:end
endlocal
