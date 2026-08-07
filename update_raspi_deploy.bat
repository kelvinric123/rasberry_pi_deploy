@echo off
setlocal EnableDelayedExpansion

REM ===========================================================================
REM  update_raspi_deploy.bat  --  publish the Raspberry Pi scripts to the
REM                               PUBLIC deploy repo that v2.qmed.asia pulls.
REM
REM    source      : THIS folder (the one the .bat sits in)
REM    target repo : https://github.com/kelvinric123/rasberry_pi_deploy.git
REM
REM  The target is a MIRROR, not a place to edit. Every run wipes its working
REM  tree (except .git) and re-copies this folder, so deletions and renames
REM  propagate and nobody can leave a stale script behind.
REM
REM  This .bat and its two .ps1 helpers sit inside the published folder on
REM  purpose, so the deploy repo carries the tooling that maintains it. The Pi
REM  never downloads them - /raspberry-pi/{file} only serves the allow-listed
REM  bundle, and Windows scripts are not on that list.
REM
REM  After it pushes, press "Sync" on
REM      https://v2.qmed.asia/admin/raspberry-pi
REM  and the server clones this repo, publishes the bundle, and queues every Pi.
REM
REM  Usage:
REM    update_raspi_deploy.bat                      auto timestamp message
REM    update_raspi_deploy.bat "my message"         custom commit message
REM    update_raspi_deploy.bat "msg" /y             skip the confirmation
REM    update_raspi_deploy.bat "msg" /dry           show changes, push nothing
REM    update_raspi_deploy.bat "msg" /https         push over HTTPS not SSH
REM    update_raspi_deploy.bat "msg" /src:<folder>  publish a different folder
REM ===========================================================================

set "REPO_HTTPS=https://github.com/kelvinric123/rasberry_pi_deploy.git"
set "REPO_SSH=git@github.com:kelvinric123/rasberry_pi_deploy.git"
set "BRANCH=main"

REM  Working clone lives OUTSIDE this project on purpose: a git checkout nested
REM  inside qmed4.0 would show up as a dirty tree and block normal deploys.
set "WORK=%LOCALAPPDATA%\qmed_raspi_deploy"

REM  The .bat lives IN the folder it publishes, so the default source is simply
REM  its own directory. %~dp0 carries a trailing backslash; the pushd/%CD%
REM  below normalises it away.
set "SCRIPTDIR=%~dp0"
set "SRC=%~dp0."

REM --- arguments --------------------------------------------------------------
set "MSG="
set "AUTOYES="
set "DRY="
set "USEHTTPS="
:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="/y" ( set "AUTOYES=1" & shift /1 & goto :parse_args )
if /i "%~1"=="/dry" ( set "DRY=1" & shift /1 & goto :parse_args )
if /i "%~1"=="/https" ( set "USEHTTPS=1" & shift /1 & goto :parse_args )
set "ARG=%~1"
if /i "!ARG:~0,5!"=="/src:" ( set "SRC=!ARG:~5!" & shift /1 & goto :parse_args )
if not defined MSG set "MSG=%~1"
shift /1
goto :parse_args
:args_done

echo.
echo ===========================================================
echo   QMED RASPBERRY PI DEPLOY  -^>  %REPO_HTTPS%
if defined DRY echo   MODE: DRY RUN  --  nothing will be committed or pushed
echo ===========================================================
echo.

REM --- resolve and validate the source folder ---------------------------------
if not exist "%SRC%\" goto :no_source
pushd "%SRC%" >nul 2>&1
if errorlevel 1 goto :no_source
set "SRC=%CD%"
popd
echo Source     : %SRC%
echo Mirror     : %WORK%
echo Branch     : %BRANCH%

REM  The server rejects a bundle that is missing any of these, so catch it here
REM  instead of after a push that can never be synced.
set "MISSING="
for %%f in (server.py start_local_server.sh video_sync.sh heartbeat.sh kiosk.sh net_watchdog.sh self_update.sh) do (
    if not exist "%SRC%\%%f" set "MISSING=!MISSING! %%f"
)
if defined MISSING goto :incomplete

REM  Not installed on devices, but served by /raspberry-pi/{file} - a fresh Pi
REM  install breaks without them.
set "WARN="
for %%f in (install.sh setup.sh bootstrap_update.sh) do (
    if not exist "%SRC%\%%f" set "WARN=!WARN! %%f"
)
if defined WARN (
    echo.
    echo [WARN] Not in the source folder:!WARN!
    echo        New-Pi installs curl these from the server - publish them too.
)

REM --- bundle version the fleet will end up on --------------------------------
set "BUNDLE="
for /f "delims=" %%v in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPTDIR%raspi_bundle_version.ps1" -Path "%SRC%" 2^>nul') do set "BUNDLE=%%v"
if defined BUNDLE echo Bundle ver : %BUNDLE%   ^(admin page must show this after Sync^)
echo.

REM --- make sure git is here --------------------------------------------------
git --version >nul 2>&1
if errorlevel 1 goto :no_git

REM --- create or refresh the mirror clone --------------------------------------
if exist "%WORK%\.git\" goto :have_clone

echo Cloning %REPO_HTTPS% ...
if exist "%WORK%\" rmdir /s /q "%WORK%" >nul 2>&1
git clone "%REPO_HTTPS%" "%WORK%"
if errorlevel 1 goto :clone_failed
goto :clone_ready

:have_clone
echo Refreshing mirror ...
git -C "%WORK%" remote set-url origin "%REPO_HTTPS%"
git -C "%WORK%" fetch origin
if errorlevel 1 goto :clone_failed

:clone_ready
REM  Push over SSH by default - the same key that pushes this project's origin.
REM  /https switches to the HTTPS URL if you authenticate with a credential
REM  manager / personal access token instead.
if defined USEHTTPS (
    git -C "%WORK%" remote set-url --push origin "%REPO_HTTPS%"
    echo Push over  : HTTPS
) else (
    git -C "%WORK%" remote set-url --push origin "%REPO_SSH%"
    echo Push over  : SSH
)

REM  Land on the remote tip so the push can never be a non-fast-forward. A repo
REM  with no commits yet has no origin/main - just start the branch.
git -C "%WORK%" rev-parse --verify --quiet "refs/remotes/origin/%BRANCH%" >nul 2>&1
if errorlevel 1 (
    echo Remote branch "%BRANCH%" does not exist yet - starting it.
    git -C "%WORK%" checkout -B "%BRANCH%" >nul 2>&1
) else (
    git -C "%WORK%" checkout -B "%BRANCH%" "origin/%BRANCH%" >nul 2>&1
    if errorlevel 1 goto :fail
    git -C "%WORK%" reset --hard "origin/%BRANCH%" >nul 2>&1
)

REM  These scripts run on Linux. If git ever rewrote them to CRLF the Pi would
REM  fail with "bad interpreter: /bin/bash^M", so pin LF in the mirror itself
REM  AND ship a .gitattributes so the server's checkout is LF too.
git -C "%WORK%" config core.autocrlf false
git -C "%WORK%" config core.safecrlf false

REM --- mirror the source folder ------------------------------------------------
echo.
echo Mirroring source into the clone ...
REM  ".git*" not ".git" - the old raspberry_pi folder carries an archived
REM  nested repo (.git-raspi_tv-backup, ~110 MB of pack files) that a bare
REM  ".git" exclusion does NOT match. Publishing that to a public repo would
REM  leak the whole raspi_tv history. The wildcard also protects the mirror's
REM  own .git from /MIR's purge.
robocopy "%SRC%" "%WORK%" /MIR ^
    /XD ".git*" ".vscode" ".idea" "__pycache__" "node_modules" ".venv" "venv" ^
    /XF "*.log" "*.tmp" "*.bak" "*.zip" "*.img" "Thumbs.db" "desktop.ini" ^
    /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 goto :copy_failed

REM  Backstop for anything the exclusions did not anticipate: a deploy repo of
REM  shell scripts is well under a megabyte, so a fat mirror means something
REM  got swept in that does not belong in a PUBLIC repository.
set "MIRRORKB="
for /f "delims=" %%k in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPTDIR%raspi_mirror_size.ps1" -Path "%WORK%" 2^>nul') do set "MIRRORKB=%%k"
if not defined MIRRORKB goto :size_unknown
echo Mirror size: !MIRRORKB! KB
if !MIRRORKB! GTR 20480 goto :too_big
goto :size_ok

:size_unknown
echo [WARN] Could not measure the mirror size - skipping the size guard.
echo        Check %WORK% by hand if this push looks unusually large.

:size_ok

REM  Written AFTER the mirror: /MIR would delete anything the source lacks.
REM  LF for everything the Pi runs - a CRLF shell script dies with
REM  "bad interpreter: /bin/bash^M". CRLF for the Windows tooling, which is
REM  mirrored into the repo alongside it.
(
    echo * text=auto eol=lf
    echo *.sh text eol=lf
    echo *.py text eol=lf
    echo *.md text eol=lf
    echo *.bat text eol=crlf
    echo *.ps1 text eol=crlf
) > "%WORK%\.gitattributes"

(
    echo # QMed Raspberry Pi deploy mirror
    echo.
    echo DO NOT EDIT FILES IN THIS REPOSITORY.
    echo.
    echo It is a generated mirror of qmed4.0/raspberry_pi_v2.1 in the main QMed
    echo repository. Every run of update_raspi_deploy.bat wipes this tree and
    echo re-copies that folder, so anything edited here is lost on the next run.
    echo.
    echo Edit the scripts in the main repository, then run the .bat again from
    echo there. The copy of the .bat in this repo is a mirrored artifact.
    echo.
    echo The QMed server clones this repo when an admin presses "Sync" on
    echo https://v2.qmed.asia/admin/raspberry-pi. See README.md for what each
    echo script does.
) > "%WORK%\MIRROR.md"

REM --- stage --------------------------------------------------------------------
git -C "%WORK%" add -A
if errorlevel 1 goto :fail

REM  Keep the executable bit on scripts. The server chmods them after a sync as
REM  well, but a correct mode here means the repo is right for anyone who
REM  clones it by hand.
for %%f in (server.py start_local_server.sh video_sync.sh heartbeat.sh kiosk.sh net_watchdog.sh self_update.sh install.sh setup.sh bootstrap_update.sh) do (
    if exist "%WORK%\%%f" git -C "%WORK%" update-index --chmod=+x "%%f" >nul 2>&1
)

git -C "%WORK%" diff --cached --quiet
if errorlevel 1 (
    echo.
    echo Changes to publish:
    git -C "%WORK%" --no-pager diff --cached --stat
) else (
    echo.
    echo No changes - the deploy repo already matches the source folder.
    if not defined DRY (
        echo Nothing to push. The fleet is already able to sync bundle %BUNDLE%.
    )
    goto :done_nochange
)

if defined DRY goto :dry_done

REM --- confirm --------------------------------------------------------------------
if not defined MSG (
    for /f "delims=" %%t in ('powershell -NoProfile -Command "Get-Date -Format \"yyyy-MM-dd HH:mm:ss\""') do set "MSG=raspi scripts %%t"
)

if not defined AUTOYES (
    echo.
    echo This publishes the files above to:
    echo    %REPO_HTTPS%
    echo Every Raspberry Pi will install them once you press Sync on the admin page.
    echo.
    set "ANSWER="
    set /p "ANSWER=Continue? [y/N] "
    if /i not "!ANSWER!"=="y" goto :cancelled
)

REM --- commit and push --------------------------------------------------------------
echo.
git -C "%WORK%" -c user.name="QMed Deploy" -c user.email="deploy@qmed.asia" commit -m "!MSG!"
if errorlevel 1 goto :fail

echo Pushing to %BRANCH% ...
git -C "%WORK%" push origin "HEAD:refs/heads/%BRANCH%"
if errorlevel 1 goto :push_failed

set "SHA="
for /f "delims=" %%s in ('git -C "%WORK%" rev-parse --short HEAD 2^>nul') do set "SHA=%%s"

echo.
echo ===========================================================
echo   PUBLISHED  %SHA%  to %BRANCH%
echo ===========================================================
echo.
echo Next:
echo   1. Open  https://v2.qmed.asia/admin/raspberry-pi
echo   2. Press Sync
echo   3. The card should report commit %SHA% and bundle version %BUNDLE%
echo.
echo Server .env must contain:
echo   RASPI_SCRIPTS_REPO_URL=%REPO_HTTPS%
echo   RASPI_SCRIPTS_BRANCH=%BRANCH%
echo   RASPI_SCRIPTS_SUBDIR=
echo.
endlocal
exit /b 0

REM ---------------------------------------------------------------------------
:done_nochange
echo.
endlocal
exit /b 0

:dry_done
echo.
echo DRY RUN - nothing was committed or pushed.
echo The mirror is staged at: %WORK%
endlocal
exit /b 0

:cancelled
echo.
echo Cancelled - nothing was pushed. The mirror at %WORK% is left staged.
endlocal
exit /b 1

:incomplete
echo.
echo [ERROR] The source folder is missing bundle files:!MISSING!
echo.
echo         The server refuses to publish an incomplete bundle, so this push
echo         could never be synced. Check /src: points at the right folder.
echo         Source was: %SRC%
endlocal
exit /b 1

:no_source
echo.
echo [ERROR] Source folder not found: %SRC%
echo         Pass another one with  /src:C:\path\to\scripts
endlocal
exit /b 1

:no_git
echo.
echo [ERROR] git is not on PATH. Install Git for Windows, or run this from
echo         a shell that has git available.
endlocal
exit /b 1

:clone_failed
echo.
echo [ERROR] Could not clone or fetch %REPO_HTTPS%
echo.
echo   * "repository not found" means the repo does not exist yet, or is still
echo     private. Create it on GitHub and make it PUBLIC - the QMed server
echo     clones it with credential prompts disabled and cannot log in.
echo   * Check network / proxy if the host could not be resolved.
echo.
endlocal
exit /b 1

:copy_failed
echo.
echo [ERROR] robocopy could not mirror the source into %WORK%
echo         Check that no editor or shell is holding a file open there.
endlocal
exit /b 1

:too_big
echo.
echo [ERROR] The mirror is %MIRRORKB% KB - far too large for a scripts repo.
echo.
echo         Something got swept in that should not be published. Look in
echo            %WORK%
echo         for build output, archives, virtualenvs or a nested .git folder,
echo         and remove it from the source folder before publishing.
echo.
echo         Nothing was committed or pushed.
endlocal
exit /b 1

:push_failed
echo.
echo [ERROR] Push failed.
echo.
echo   * "Permission denied (publickey)" - your SSH key has no write access to
echo     kelvinric123/rasberry_pi_deploy. Re-run with /https to push over HTTPS
echo     instead, or add the key on GitHub.
echo   * "non-fast-forward" - someone pushed directly to the repo. Re-run this
echo     script; it resets onto the remote tip before mirroring.
echo.
endlocal
exit /b 1

:fail
echo.
echo [ERROR] A git command failed - see the output above.
endlocal
exit /b 1
