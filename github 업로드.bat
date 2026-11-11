@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

title GitHub 업데이트
cd /d "%~dp0"

echo ========================================
echo          GitHub 업데이트
echo ========================================
echo.

git --version >nul 2>&1
if errorlevel 1 (
    echo [오류] Git이 설치되어 있지 않거나 PATH에 없습니다.
    pause
    exit /b 1
)

REM Git 저장소가 아니면 초기화
if not exist ".git" (
    echo [초기 설정] Git 저장소가 아닙니다.
    echo Git 저장소를 생성합니다...
    echo.

    git init
    if errorlevel 1 goto ERROR

    git branch -M main

    echo.
    set /p REPO_URL="GitHub 저장소 URL 입력: "

    if "!REPO_URL!"=="" (
        echo [오류] 저장소 URL이 필요합니다.
        pause
        exit /b 1
    )

    git remote add origin "!REPO_URL!"
    if errorlevel 1 goto ERROR

    echo.
    echo [완료] GitHub 저장소 연결 완료
    echo.

    REM 원격 main 브랜치가 이미 있는지 확인
    echo [초기 동기화] GitHub 저장소 확인 중...
    git ls-remote --exit-code --heads origin main >nul 2>&1

    if not errorlevel 1 (
        echo 원격 main 브랜치가 이미 있습니다.
        echo README / LICENSE 등의 기존 커밋을 병합합니다...
        echo.

        git pull origin main --allow-unrelated-histories --no-edit

        if errorlevel 1 (
            echo.
            echo [오류] 원격 저장소와 병합 중 문제가 발생했습니다.
            echo 충돌이 있다면 파일을 수정한 뒤 다시 실행하세요.
            goto ERROR
        )
    )
)

echo [1/4] 현재 상태
echo ----------------------------------------
git status
echo.

echo [2/4] 변경사항 추가
git add .
if errorlevel 1 goto ERROR

REM 실제 변경사항이 있는지 확인
git diff --cached --quiet
if not errorlevel 1 goto NO_CHANGES

goto COMMIT


:NO_CHANGES
echo.
echo 변경사항이 없습니다.
echo GitHub와 동기화만 확인합니다...
echo.

REM upstream 존재 여부 확인
git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >nul 2>&1

if errorlevel 1 (
    echo upstream이 없습니다. origin/main으로 연결합니다...

    REM 원격 main이 존재하면 먼저 동기화
    git ls-remote --exit-code --heads origin main >nul 2>&1

    if not errorlevel 1 (
        git pull origin main --allow-unrelated-histories --no-edit
        if errorlevel 1 goto ERROR
    )

    git push -u origin main
) else (
    git push
)

if errorlevel 1 goto ERROR
goto SUCCESS


:COMMIT
echo.
echo [3/4] 커밋
git commit -m "업데이트"
if errorlevel 1 goto ERROR

echo.
echo [4/4] GitHub Push

REM upstream 존재 여부 확인
git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >nul 2>&1

if errorlevel 1 (
    echo upstream이 없습니다.

    REM 원격 main이 이미 있다면 push 전에 병합
    git ls-remote --exit-code --heads origin main >nul 2>&1

    if not errorlevel 1 (
        echo 원격 main 브랜치가 이미 있습니다.
        echo 먼저 원격 변경사항을 병합합니다...
        echo.

        git pull origin main --allow-unrelated-histories --no-edit

        if errorlevel 1 (
            echo.
            echo [오류] 병합 충돌이 발생했습니다.
            echo 충돌 파일을 수정한 뒤 다시 실행하세요.
            goto ERROR
        )
    )

    git push -u origin main
) else (
    git push
)

if errorlevel 1 goto ERROR
goto SUCCESS


:SUCCESS
echo.
echo ========================================
echo        업데이트 완료!
echo ========================================
pause
exit /b 0


:ERROR
echo.
echo ========================================
echo       업데이트 중 오류 발생
echo ========================================
echo.
echo 위의 Git 메시지를 확인하세요.
pause
exit /b 1