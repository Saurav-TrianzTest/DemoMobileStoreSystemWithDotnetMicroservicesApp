@echo off
setlocal enabledelayedexpansion

echo ============================================
echo   Microservices Docker Build and Push
echo ============================================
echo.

set PROJECT_NAME=microservices-app

REM Define services (name|project_path|project_name)
set SERVICE_1=catalog-api^|src/catalog/Catalog.API^|Catalog.API
set SERVICE_2=basket-api^|src/Basket/BasketAPI^|BasketAPI
set SERVICE_3=ordering-api^|src/Ordering/Ordering^|Ordering.API
set SERVICE_4=api-gateway^|src/ApiGateway/ApiGateway^|ApiGateway
set SERVICE_5=ui-layer^|src/UI_Layer^|AspnetRunBasics
set SERVICE_COUNT=5

REM Select registry
echo Select Docker Registry:
echo 1. AWS ECR
echo 2. Docker Hub
set /p REGISTRY_CHOICE="Enter choice (1 or 2): "

if "!REGISTRY_CHOICE!"=="1" (
  REM AWS ECR Configuration
  set /p AWS_REGION="Enter AWS Region (e.g., us-east-1): "
  set /p AWS_ACCOUNT_ID="Enter AWS Account ID: "
  
  set REGISTRY_URL=!AWS_ACCOUNT_ID!.dkr.ecr.!AWS_REGION!.amazonaws.com
  
  echo.
  echo Authenticating with AWS ECR...
  for /f "delims=" %%i in ('aws ecr get-login-password --region !AWS_REGION!') do set ECR_PASSWORD=%%i
  echo !ECR_PASSWORD! | docker login --username AWS --password-stdin !REGISTRY_URL!
  
  if !ERRORLEVEL! neq 0 (
    echo ERROR: ECR authentication failed
    exit /b 1
  )
  
  echo ECR authentication successful
  
) else if "!REGISTRY_CHOICE!"=="2" (
  REM Docker Hub Configuration
  set /p DOCKER_USERNAME="Enter Docker Hub username: "
  set /p DOCKER_PASSWORD="Enter Docker Hub password/token: "
  
  echo.
  echo Authenticating with Docker Hub...
  echo !DOCKER_PASSWORD! | docker login --username !DOCKER_USERNAME! --password-stdin
  
  if !ERRORLEVEL! neq 0 (
    echo ERROR: Docker Hub authentication failed
    exit /b 1
  )
  
  set REGISTRY_URL=!DOCKER_USERNAME!
  echo Docker Hub authentication successful
  
) else (
  echo Invalid choice. Exiting.
  exit /b 1
)

echo.
set /p IMAGE_TAG="Enter image tag (default: latest): "
if "!IMAGE_TAG!"=="" set IMAGE_TAG=latest

REM Sanitize tag (basic Windows version)
set IMAGE_TAG=!IMAGE_TAG: =-!
set IMAGE_TAG=!IMAGE_TAG:_=-!
if "!IMAGE_TAG!"=="" set IMAGE_TAG=latest

echo.
echo Building and pushing microservices...
echo.

REM Build and push each service
for /l %%i in (1,1,!SERVICE_COUNT!) do (
  set SERVICE_DEF=!SERVICE_%%i!
  
  for /f "tokens=1,2,3 delims=^|" %%a in ("!SERVICE_DEF!") do (
    set SERVICE_NAME=%%a
    set PROJECT_PATH=%%b
    set PROJECT_NAME=%%c
    
    REM Sanitize service name
    set IMAGE_NAME=!SERVICE_NAME: =-!
    set IMAGE_NAME=!IMAGE_NAME:_=-!
    
    if "!REGISTRY_CHOICE!"=="1" (
      REM ECR: Create repository if needed
      set ECR_REPO=!IMAGE_NAME!
      echo Checking ECR repository: !ECR_REPO!
      aws ecr describe-repositories --repository-names !ECR_REPO! --region !AWS_REGION! >nul 2>&1
      if !ERRORLEVEL! neq 0 (
        echo Creating ECR repository: !ECR_REPO!
        aws ecr create-repository --repository-name !ECR_REPO! --region !AWS_REGION!
      )
      set FULL_IMAGE_NAME=!REGISTRY_URL!/!ECR_REPO!:!IMAGE_TAG!
    ) else (
      set FULL_IMAGE_NAME=!REGISTRY_URL!/!IMAGE_NAME!:!IMAGE_TAG!
    )
    
    echo.
    echo === Building !SERVICE_NAME! ===
    echo Project Path: !PROJECT_PATH!
    echo Project Name: !PROJECT_NAME!
    echo Image: !FULL_IMAGE_NAME!
    echo.
    
    docker build -f Dockerfile --build-arg PROJECT_PATH=!PROJECT_PATH! --build-arg PROJECT_NAME=!PROJECT_NAME! -t !FULL_IMAGE_NAME! .
    
    if !ERRORLEVEL! neq 0 (
      echo ERROR: Docker build failed for !SERVICE_NAME!
      exit /b 1
    )
    
    echo.
    echo Pushing !FULL_IMAGE_NAME!...
    docker push !FULL_IMAGE_NAME!
    
    if !ERRORLEVEL! neq 0 (
      echo ERROR: Docker push failed for !SERVICE_NAME!
      exit /b 1
    )
    
    echo Successfully built and pushed !SERVICE_NAME!
  )
)

echo.
echo ============================================
echo   All microservices built and pushed!
echo ============================================
echo.
echo Next steps:
echo 1. Run scripts\deploy-image.bat to deploy to AWS ECS
echo 2. Or use docker-compose up to run locally
echo.

endlocal