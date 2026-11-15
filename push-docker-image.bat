@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ============================================================
REM  push-docker-image.bat
REM  Pull a Docker image -> save to tar -> split into 10 MB 7z parts
REM  -> new git branch in the repo -> commit -> push
REM ============================================================

REM ---------- Config (edit if needed) ----------
set "REPO_DIR=E:\Docker-IE\Docker-Images"
set "SEVENZIP=C:\Program Files\7-Zip\7z.exe"
set "WORK_DIR=%TEMP%\docker-split"
set "VOLUME_SIZE=10m"
REM ---------------------------------------------

REM ---------- Pre-checks ----------
where docker >nul 2>&1 || (echo [ERROR] docker not found in PATH.& goto :fail)
where git    >nul 2>&1 || (echo [ERROR] git not found in PATH.& goto :fail)
if not exist "%SEVENZIP%" (
    where 7z >nul 2>&1 && (set "SEVENZIP=7z") || (echo [ERROR] 7-Zip not found at "%SEVENZIP%" or in PATH.& goto :fail)
)
if not exist "%REPO_DIR%\.git" (echo [ERROR] "%REPO_DIR%" is not a git repo.& goto :fail)

REM ---------- Input ----------
set "IMAGE="
set "TAG="
set /p "IMAGE=Docker image name (e.g. nginx or harbor.local/proj/app): "
if "%IMAGE%"=="" (echo [ERROR] Image name is required.& goto :fail)
set /p "TAG=Tag [latest]: "
if "%TAG%"=="" set "TAG=latest"

set "FULL_IMAGE=%IMAGE%:%TAG%"

REM Safe name for files/branch: replace / and : with _
set "SAFE=%IMAGE%"
set "SAFE=%SAFE:/=_%"
set "SAFE=%SAFE::=_%"
set "SAFE_TAG=%TAG::=_%"
set "BASE_NAME=%SAFE%_%SAFE_TAG%"
set "BRANCH=image/%BASE_NAME%"
set "TARGET_DIR=%REPO_DIR%\images\%BASE_NAME%"

echo.
echo   Image  : %FULL_IMAGE%
echo   Branch : %BRANCH%
echo   Folder : %TARGET_DIR%
echo.

REM ---------- Branch must not exist already ----------
pushd "%REPO_DIR%"
git rev-parse --verify --quiet "refs/heads/%BRANCH%" >nul && (
    echo [ERROR] Local branch "%BRANCH%" already exists.
    popd & goto :fail
)
git ls-remote --exit-code --heads origin "%BRANCH%" >nul 2>&1 && (
    echo [ERROR] Remote branch "%BRANCH%" already exists on origin.
    popd & goto :fail
)
for /f "delims=" %%B in ('git rev-parse --abbrev-ref HEAD') do set "ORIG_BRANCH=%%B"
popd

REM ---------- Pull ----------
echo [1/5] Pulling %FULL_IMAGE% ...
docker pull "%FULL_IMAGE%" || (echo [ERROR] docker pull failed.& goto :fail)

REM ---------- Save ----------
if exist "%WORK_DIR%" rmdir /s /q "%WORK_DIR%"
mkdir "%WORK_DIR%" || goto :fail
set "TAR_FILE=%WORK_DIR%\%BASE_NAME%.tar"

echo [2/5] Saving image to %TAR_FILE% ...
docker save -o "%TAR_FILE%" "%FULL_IMAGE%" || (echo [ERROR] docker save failed.& goto :fail)

REM ---------- Split with 7-Zip ----------
echo [3/5] Compressing and splitting into %VOLUME_SIZE% parts ...
"%SEVENZIP%" a -t7z -mx=5 -v%VOLUME_SIZE% "%WORK_DIR%\%BASE_NAME%.7z" "%TAR_FILE%" >nul
if errorlevel 1 (echo [ERROR] 7-Zip failed.& goto :fail)
del /q "%TAR_FILE%"

REM ---------- New branch + copy ----------
echo [4/5] Creating branch %BRANCH% and copying parts ...
pushd "%REPO_DIR%"
git checkout -b "%BRANCH%" || (popd & goto :fail)

if not exist "%TARGET_DIR%" mkdir "%TARGET_DIR%"
copy /y "%WORK_DIR%\%BASE_NAME%.7z.*" "%TARGET_DIR%\" >nul || (popd & goto :fail)

> "%TARGET_DIR%\RESTORE.txt" (
    echo Image: %FULL_IMAGE%
    echo.
    echo To restore:
    echo   7z x %BASE_NAME%.7z.001
    echo   docker load -i %BASE_NAME%.tar
)

REM ---------- Commit + push ----------
echo [5/5] Committing and pushing ...
git add "images/%BASE_NAME%"
git commit -m "Add docker image %FULL_IMAGE% (split 7z, %VOLUME_SIZE% parts)" || (popd & goto :fail)
git push -u origin "%BRANCH%" || (echo [ERROR] git push failed.& popd & goto :fail)

REM Go back to the branch you were on
git checkout "%ORIG_BRANCH%" >nul 2>&1
popd

rmdir /s /q "%WORK_DIR%"

echo.
echo [DONE] %FULL_IMAGE% pushed to branch %BRANCH%
endlocal
exit /b 0

:fail
echo.
echo [FAILED] See messages above.
endlocal
exit /b 1