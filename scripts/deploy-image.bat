@echo off
setlocal enabledelayedexpansion

REM Script to deploy Docker image to AWS ECS Fargate

echo ==========================================
echo AWS ECS Fargate Deployment Script
echo ==========================================
echo.

REM Configuration
set PROJECT_NAME=dmstcont
set TASK_FAMILY=%PROJECT_NAME%-task
set SERVICE_NAME=%PROJECT_NAME%-service

set TASK_DEF_FILE=ecs\task-definition.json
set SERVICE_DEF_FILE=ecs\service-definition.json

REM Prompt for AWS configuration
echo AWS Configuration
echo -----------------
set /p "AWS_REGION=Enter AWS region (e.g., us-east-1): "
set /p "CLUSTER_NAME=Enter ECS cluster name (e.g., my-ecs-cluster): "
echo.

REM Set AWS region
set AWS_DEFAULT_REGION=!AWS_REGION!

REM Get AWS Account ID
echo Retrieving AWS Account ID...
for /f "delims=" %%i in ('aws sts get-caller-identity --query Account --output text') do set ACCOUNT_ID=%%i

if "!ACCOUNT_ID!"==" " (
    echo Error: Failed to retrieve AWS Account ID. Check AWS CLI configuration.
    exit /b 1
)

echo AWS Account ID: !ACCOUNT_ID!
echo.

REM Network Configuration
echo Network Configuration
echo ---------------------
set /p "VPC_ID=Enter VPC ID (e.g., vpc-0abc123def456): "
set /p "SUBNET_IDS=Enter Subnet IDs comma-separated (e.g., subnet-0abc123,subnet-0def456): "
set /p "SECURITY_GROUP=Enter Security Group ID (e.g., sg-0abc123def): "
echo.

REM Parse subnets
for /f "tokens=1,2 delims=," %%a in ("!SUBNET_IDS!") do (
    set SUBNET_1=%%a
    set SUBNET_2=%%b
)
if "!SUBNET_2!"=="" set SUBNET_2=!SUBNET_1!

REM Docker Image Configuration
echo Docker Image Configuration
echo ---------------------------
set /p "IMAGE_URI=Enter Docker image URI (e.g., 123456789.dkr.ecr.us-east-1.amazonaws.com/dmstcont:latest): "
echo.

REM Check/create ECS cluster
echo Checking ECS cluster...
aws ecs describe-clusters --clusters !CLUSTER_NAME! --region !AWS_REGION! >nul 2>&1
if !ERRORLEVEL! neq 0 (
    echo Cluster does not exist. Creating ECS cluster...
    aws ecs create-cluster --cluster-name !CLUSTER_NAME! --region !AWS_REGION!
    echo Cluster created successfully
)
echo.

REM Load Balancer Configuration
set /p "USE_LB=Do you need a load balancer for this service? (y/n): "
echo.

if /i "!USE_LB!"=="y" (
    echo Creating Application Load Balancer and Target Group...
    
    set ALB_NAME=%PROJECT_NAME%-alb
    echo Creating ALB: !ALB_NAME!
    for /f "delims=" %%i in ('aws elbv2 create-load-balancer --name !ALB_NAME! --subnets !SUBNET_1! !SUBNET_2! --security-groups !SECURITY_GROUP! --scheme internet-facing --type application --ip-address-type ipv4 --region !AWS_REGION! --query "LoadBalancers[0].LoadBalancerArn" --output text 2^>nul') do set ALB_ARN=%%i
    
    if "!ALB_ARN!"=="" (
        echo ALB may already exist. Attempting to describe existing ALB...
        for /f "delims=" %%i in ('aws elbv2 describe-load-balancers --names !ALB_NAME! --region !AWS_REGION! --query "LoadBalancers[0].LoadBalancerArn" --output text 2^>nul') do set ALB_ARN=%%i
    )
    
    if "!ALB_ARN!"=="" (
        echo Error: Failed to create or find ALB
        exit /b 1
    )
    
    echo ALB ARN: !ALB_ARN!
    
    set TG_NAME=%PROJECT_NAME%-tg
    echo Creating Target Group: !TG_NAME!
    for /f "delims=" %%i in ('aws elbv2 create-target-group --name !TG_NAME! --protocol HTTP --port 80 --vpc-id !VPC_ID! --target-type ip --health-check-enabled --health-check-protocol HTTP --health-check-path /health --health-check-interval-seconds 30 --health-check-timeout-seconds 5 --healthy-threshold-count 2 --unhealthy-threshold-count 3 --region !AWS_REGION! --query "TargetGroups[0].TargetGroupArn" --output text 2^>nul') do set TARGET_GROUP_ARN=%%i
    
    if "!TARGET_GROUP_ARN!"=="" (
        echo Target Group may already exist. Attempting to describe existing Target Group...
        for /f "delims=" %%i in ('aws elbv2 describe-target-groups --names !TG_NAME! --region !AWS_REGION! --query "TargetGroups[0].TargetGroupArn" --output text 2^>nul') do set TARGET_GROUP_ARN=%%i
    )
    
    if "!TARGET_GROUP_ARN!"=="" (
        echo Error: Failed to create or find Target Group
        exit /b 1
    )
    
    echo Target Group ARN: !TARGET_GROUP_ARN!
    
    echo Creating ALB Listener...
    aws elbv2 create-listener --load-balancer-arn !ALB_ARN! --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=!TARGET_GROUP_ARN! --region !AWS_REGION! >nul 2>&1
    
    echo Load Balancer setup completed
    echo.
    
    REM Update service definition with load balancer
    jq --arg tg "!TARGET_GROUP_ARN!" ".loadBalancers[0].targetGroupArn = $tg | .healthCheckGracePeriodSeconds = 300" !SERVICE_DEF_FILE! > !SERVICE_DEF_FILE!.tmp
    move /y !SERVICE_DEF_FILE!.tmp !SERVICE_DEF_FILE! >nul
) else (
    echo Skipping load balancer configuration
    jq "del(.loadBalancers) | del(.healthCheckGracePeriodSeconds)" !SERVICE_DEF_FILE! > !SERVICE_DEF_FILE!.tmp
    move /y !SERVICE_DEF_FILE!.tmp !SERVICE_DEF_FILE! >nul
    echo.
)

REM Create CloudWatch Log Group
echo Creating CloudWatch Log Group...
set LOG_GROUP=/ecs/%PROJECT_NAME%
aws logs create-log-group --log-group-name !LOG_GROUP! --region !AWS_REGION! >nul 2>&1
echo.

REM Replace placeholders in task definition
echo Preparing task definition...
copy /y !TASK_DEF_FILE! !TASK_DEF_FILE!.tmp >nul
powershell -Command "(Get-Content '!TASK_DEF_FILE!.tmp') -replace '{{IMAGE_URI}}','!IMAGE_URI!' -replace '{{AWS_REGION}}','!AWS_REGION!' -replace '{{ACCOUNT_ID}}','!ACCOUNT_ID!' | Set-Content '!TASK_DEF_FILE!.tmp'"

REM Register task definition
echo Registering ECS task definition...
for /f "delims=" %%i in ('aws ecs register-task-definition --cli-input-json file://!TASK_DEF_FILE!.tmp --region !AWS_REGION! --query "taskDefinition.taskDefinitionArn" --output text') do set TASK_DEF_ARN=%%i

if "!TASK_DEF_ARN!"=="" (
    echo Error: Failed to register task definition
    del !TASK_DEF_FILE!.tmp
    exit /b 1
)

echo Task Definition ARN: !TASK_DEF_ARN!
del !TASK_DEF_FILE!.tmp
echo.

REM Replace placeholders in service definition
echo Preparing service definition...
copy /y !SERVICE_DEF_FILE! !SERVICE_DEF_FILE!.tmp >nul
powershell -Command "(Get-Content '!SERVICE_DEF_FILE!.tmp') -replace '{{CLUSTER_NAME}}','!CLUSTER_NAME!' -replace '{{SUBNET_1}}','!SUBNET_1!' -replace '{{SUBNET_2}}','!SUBNET_2!' -replace '{{SECURITY_GROUP}}','!SECURITY_GROUP!' | Set-Content '!SERVICE_DEF_FILE!.tmp'"

REM Check if service exists
echo Checking if service exists...
for /f "delims=" %%i in ('aws ecs describe-services --cluster !CLUSTER_NAME! --services !SERVICE_NAME! --region !AWS_REGION! --query "services[?status==`ACTIVE`].serviceName" --output text 2^>nul') do set EXISTING_SERVICE=%%i

if "!EXISTING_SERVICE!"=="" (
    echo Service does not exist. Creating new service...
    aws ecs create-service --cli-input-json file://!SERVICE_DEF_FILE!.tmp --region !AWS_REGION! >nul
    if !ERRORLEVEL! neq 0 (
        echo Error: Failed to create service
        del !SERVICE_DEF_FILE!.tmp
        exit /b 1
    )
    echo Service created successfully
) else (
    echo Service exists. Updating service...
    aws ecs update-service --cluster !CLUSTER_NAME! --service !SERVICE_NAME! --task-definition !TASK_DEF_ARN! --force-new-deployment --region !AWS_REGION! >nul
    if !ERRORLEVEL! neq 0 (
        echo Error: Failed to update service
        del !SERVICE_DEF_FILE!.tmp
        exit /b 1
    )
    echo Service updated successfully
)

del !SERVICE_DEF_FILE!.tmp
echo.

REM Wait for service stability
echo Waiting for service to stabilize (this may take several minutes)...
aws ecs wait services-stable --cluster !CLUSTER_NAME! --services !SERVICE_NAME! --region !AWS_REGION!
if !ERRORLEVEL! neq 0 (
    echo Warning: Service did not stabilize within the expected time
    echo Check the ECS console for service status
) else (
    echo Service is stable
)
echo.

REM Verify deployment
echo Verifying deployment...
for /f "delims=" %%i in ('aws ecs describe-services --cluster !CLUSTER_NAME! --services !SERVICE_NAME! --region !AWS_REGION! --query "services[0].runningCount" --output text') do set RUNNING_COUNT=%%i
for /f "delims=" %%i in ('aws ecs describe-services --cluster !CLUSTER_NAME! --services !SERVICE_NAME! --region !AWS_REGION! --query "services[0].desiredCount" --output text') do set DESIRED_COUNT=%%i

echo Service Status:
echo   Running Tasks: !RUNNING_COUNT!
echo   Desired Tasks: !DESIRED_COUNT!
echo.

if /i "!USE_LB!"=="y" (
    for /f "delims=" %%i in ('aws elbv2 describe-load-balancers --load-balancer-arns !ALB_ARN! --region !AWS_REGION! --query "LoadBalancers[0].DNSName" --output text') do set ALB_DNS=%%i
    echo Application URL: http://!ALB_DNS!
    echo.
)

echo CloudWatch Logs: !LOG_GROUP!
echo.

echo ==========================================
echo Deployment Completed Successfully
echo ==========================================
echo.
echo Troubleshooting:
echo - View logs: aws logs tail !LOG_GROUP! --follow --region !AWS_REGION!
echo - List tasks: aws ecs list-tasks --cluster !CLUSTER_NAME! --service-name !SERVICE_NAME! --region !AWS_REGION!
echo - Describe service: aws ecs describe-services --cluster !CLUSTER_NAME! --services !SERVICE_NAME! --region !AWS_REGION!
echo.

endlocal