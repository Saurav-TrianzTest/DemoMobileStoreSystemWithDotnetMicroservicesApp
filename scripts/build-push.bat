@echo off
setlocal enabledelayedexpansion

REM Script to build and push Docker image to container registry
REM Supports AWS ECR and Docker Hub

echo ======================================
echo Docker Build and Push Script
echo ======================================
echo.

REM Project configuration
set PROJECT_NAME=DMSTCont
set DOCKERFILE_PATH=Dockerfile

REM Sanitize image name using PowerShell
for /f "delims=" %%i in ('powershell -Command "'%PROJECT_NAME%'.ToLower() -replace '[^a-z0-9]+','-' -replace '^-+','' -replace '-+$',''"') do set IMAGE_NAME=%%i

echo Project: %PROJECT_NAME%
echo Sanitized Image Name: !IMAGE_NAME!
echo.

REM Select registry type
echo Select container registry:
echo 1. AWS ECR (Elastic Container Registry)
echo 2. Docker Hub
set /p "REGISTRY_CHOICE=Enter choice (1 or 2): "
echo.

if "!REGISTRY_CHOICE!"=="1" (
    REM AWS ECR Configuration
    echo AWS ECR Configuration
    echo ---------------------
    set /p "AWS_REGION=Enter AWS Region (e.g., us-east-1): "
    set /p "AWS_ACCOUNT_ID=Enter AWS Account ID: "
    set /p "ECR_REPO=Enter ECR Repository Name (e.g., dmstcont): "
    
    set REGISTRY_URL=!AWS_ACCOUNT_ID!.dkr.ecr.!AWS_REGION!.amazonaws.com
    
    echo.
    echo Authenticating with AWS ECR...
    aws ecr get-login-password --region !AWS_REGION! | docker login --username AWS --password-stdin !REGISTRY_URL!
    
    if !ERRORLEVEL! neq 0 (
        echo Error: ECR authentication failed
        exit /b 1
    )
    
    echo Authentication successful
    echo.
    
    REM Check if repository exists, create if not
    echo Checking ECR repository...
    aws ecr describe-repositories --repository-names !ECR_REPO! --region !AWS_REGION! >nul 2>&1
    if !ERRORLEVEL! neq 0 (
        echo Repository does not exist. Creating ECR repository...
        aws ecr create-repository --repository-name !ECR_REPO! --region !AWS_REGION!
        if !ERRORLEVEL! neq 0 (
            echo Error: Failed to create ECR repository
            exit /b 1
        )
        echo Repository created successfully
    )
    echo.
    
    REM Prompt for image tag
    set /p "IMAGE_TAG=Enter image tag (default: latest): "
    if "!IMAGE_TAG!"=="" set IMAGE_TAG=latest
    for /f "delims=" %%i in ('powershell -Command "'!IMAGE_TAG!'.ToLower() -replace '[^a-z0-9.-]+','-' -replace '^-+','' -replace '-+$',''"') do set IMAGE_TAG=%%i
    
    set FULL_IMAGE_NAME=!REGISTRY_URL!/!ECR_REPO!:!IMAGE_TAG!
    
) else if "!REGISTRY_CHOICE!"=="2" (
    REM Docker Hub Configuration
    echo Docker Hub Configuration
    echo ------------------------
    set /p "DOCKER_USERNAME=Enter Docker Hub username: "
    set /p "DOCKER_PASSWORD=Enter Docker Hub password or token: "
    
    echo.
    echo Authenticating with Docker Hub...
    echo !DOCKER_PASSWORD! | docker login --username !DOCKER_USERNAME! --password-stdin
    
    if !ERRORLEVEL! neq 0 (
        echo Error: Docker Hub authentication failed
        exit /b 1
    )
    
    echo Authentication successful
    echo.
    
    REM Prompt for image tag
    set /p "IMAGE_TAG=Enter image tag (default: latest): "
    if "!IMAGE_TAG!"=="" set IMAGE_TAG=latest
    for /f "delims=" %%i in ('powershell -Command "'!IMAGE_TAG!'.ToLower() -replace '[^a-z0-9.-]+','-' -replace '^-+','' -replace '-+$',''"') do set IMAGE_TAG=%%i
    
    set FULL_IMAGE_NAME=!DOCKER_USERNAME!/!IMAGE_NAME!:!IMAGE_TAG!
    
) else (
    echo Error: Invalid choice. Please select 1 or 2.
    exit /b 1
)

echo Full Image Name: !FULL_IMAGE_NAME!
echo.

REM Build Docker image
echo ======================================
echo Building Docker Image
echo ======================================
echo Building: !FULL_IMAGE_NAME!
echo.

docker build -f %DOCKERFILE_PATH% -t !FULL_IMAGE_NAME! .

if !ERRORLEVEL! neq 0 (
    echo Error: Docker build failed
    exit /b 1
)

echo.
echo Build completed successfully
echo.

REM Push Docker image
echo ======================================
echo Pushing Docker Image
echo ======================================
echo Pushing: !FULL_IMAGE_NAME!
echo.

docker push !FULL_IMAGE_NAME!

if !ERRORLEVEL! neq 0 (
    echo Error: Docker push failed
    exit /b 1
)

echo.
echo ======================================
echo Build and Push Completed Successfully
echo ======================================
echo.
echo Image: !FULL_IMAGE_NAME!
echo.
echo Next steps:
echo 1. Use this image URI in your ECS task definition
echo 2. Run the deploy-image.bat script to deploy to ECS
echo.

endlocal