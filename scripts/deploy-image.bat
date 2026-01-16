@echo off
setlocal enabledelayedexpansion

echo ============================================
echo   AWS ECS Fargate Deployment
echo ============================================
echo.

REM Check prerequisites
where aws >nul 2>&1
if !ERRORLEVEL! neq 0 (
  echo ERROR: aws-cli is not installed
  exit /b 1
)

REM Collect deployment parameters
set /p AWS_REGION="Enter AWS region (e.g., us-east-1): "
set /p CLUSTER_NAME="Enter ECS cluster name (e.g., microservices-cluster): "
set /p VPC_ID="Enter VPC ID (e.g., vpc-0abc123def456): "
set /p SUBNETS_INPUT="Enter Subnet IDs comma-separated (e.g., subnet-0abc123,subnet-0def456): "
set /p SECURITY_GROUP="Enter Security Group ID (e.g., sg-0abc123def): "
set /p IMAGE_URI="Enter Docker image URI (e.g., 123456789.dkr.ecr.us-east-1.amazonaws.com/app:latest): "

REM Parse subnets
for /f "tokens=1,2 delims=," %%a in ("!SUBNETS_INPUT!") do (
  set SUBNET_1=%%a
  set SUBNET_2=%%b
)
if "!SUBNET_2!"=="" set SUBNET_2=!SUBNET_1!

echo.
echo Deployment Configuration:
echo   Region: !AWS_REGION!
echo   Cluster: !CLUSTER_NAME!
echo   VPC: !VPC_ID!
echo   Subnets: !SUBNET_1!, !SUBNET_2!
echo   Security Group: !SECURITY_GROUP!
echo   Image: !IMAGE_URI!
echo.

REM Get AWS Account ID
echo Retrieving AWS Account ID...
for /f "delims=" %%i in ('aws sts get-caller-identity --query Account --output text') do set ACCOUNT_ID=%%i
echo Account ID: !ACCOUNT_ID!
echo.

REM Check/Create ECS Cluster
echo Checking ECS cluster...
aws ecs describe-clusters --clusters !CLUSTER_NAME! --region !AWS_REGION! >nul 2>&1
if !ERRORLEVEL! neq 0 (
  echo Creating ECS cluster: !CLUSTER_NAME!
  aws ecs create-cluster --cluster-name !CLUSTER_NAME! --region !AWS_REGION!
) else (
  echo Cluster !CLUSTER_NAME! exists
)
echo.

REM Load Balancer configuration
set /p NEED_LB="Do you need a load balancer for this service? (y/n): "

if /i "!NEED_LB!"=="y" (
  echo.
  echo Creating Application Load Balancer and Target Group...
  
  REM Create ALB
  set ALB_NAME=microservices-alb-!RANDOM!
  echo Creating ALB: !ALB_NAME!
  for /f "delims=" %%i in ('aws elbv2 create-load-balancer --name !ALB_NAME! --subnets !SUBNET_1! !SUBNET_2! --security-groups !SECURITY_GROUP! --scheme internet-facing --type application --region !AWS_REGION! --query LoadBalancers[0].LoadBalancerArn --output text') do set ALB_ARN=%%i
  echo ALB created: !ALB_ARN!
  
  REM Get ALB DNS
  for /f "delims=" %%i in ('aws elbv2 describe-load-balancers --load-balancer-arns !ALB_ARN! --region !AWS_REGION! --query LoadBalancers[0].DNSName --output text') do set ALB_DNS=%%i
  
  REM Create Target Group
  set TG_NAME=microservices-tg-!RANDOM!
  echo Creating Target Group: !TG_NAME!
  for /f "delims=" %%i in ('aws elbv2 create-target-group --name !TG_NAME! --protocol HTTP --port 80 --vpc-id !VPC_ID! --target-type ip --health-check-path /health --health-check-interval-seconds 30 --health-check-timeout-seconds 5 --healthy-threshold-count 2 --unhealthy-threshold-count 3 --region !AWS_REGION! --query TargetGroups[0].TargetGroupArn --output text') do set TARGET_GROUP_ARN=%%i
  echo Target Group created: !TARGET_GROUP_ARN!
  
  REM Create Listener
  echo Creating ALB Listener...
  aws elbv2 create-listener --load-balancer-arn !ALB_ARN! --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=!TARGET_GROUP_ARN! --region !AWS_REGION! >nul
  echo Listener created successfully
  echo.
  
  set USE_LB=true
) else (
  echo Skipping load balancer configuration
  set USE_LB=false
)

echo.
echo Creating CloudWatch Log Group...
set LOG_GROUP=/ecs/microservices-app
aws logs create-log-group --log-group-name !LOG_GROUP! --region !AWS_REGION! 2>nul
echo.

REM Prepare task definition
echo Preparing task definition...
set TASK_DEF_FILE=ecs\task-definition.json

if not exist "!TASK_DEF_FILE!" (
  echo ERROR: Task definition file not found: !TASK_DEF_FILE!
  exit /b 1
)

REM Replace placeholders (using PowerShell for complex string replacement)
powershell -Command "(Get-Content '!TASK_DEF_FILE!') -replace '{{IMAGE_URI}}', '!IMAGE_URI!' -replace '{{AWS_REGION}}', '!AWS_REGION!' -replace '{{ACCOUNT_ID}}', '!ACCOUNT_ID!' | Set-Content '%TEMP%\task-definition-temp.json'"

echo Registering task definition...
for /f "delims=" %%i in ('aws ecs register-task-definition --cli-input-json file://%TEMP%\task-definition-temp.json --region !AWS_REGION! --query taskDefinition.taskDefinitionArn --output text') do set TASK_DEF_ARN=%%i
echo Task definition registered: !TASK_DEF_ARN!
del "%TEMP%\task-definition-temp.json"
echo.

REM Prepare service definition
echo Preparing service definition...
set SERVICE_DEF_FILE=ecs\service-definition.json
set SERVICE_NAME=microservices-app-service

if not exist "!SERVICE_DEF_FILE!" (
  echo ERROR: Service definition file not found: !SERVICE_DEF_FILE!
  exit /b 1
)

REM Replace placeholders
if "!USE_LB!"=="true" (
  powershell -Command "(Get-Content '!SERVICE_DEF_FILE!') -replace '{{CLUSTER_NAME}}', '!CLUSTER_NAME!' -replace '{{SUBNET_1}}', '!SUBNET_1!' -replace '{{SUBNET_2}}', '!SUBNET_2!' -replace '{{SECURITY_GROUP}}', '!SECURITY_GROUP!' -replace '{{TARGET_GROUP_ARN}}', '!TARGET_GROUP_ARN!' | Set-Content '%TEMP%\service-definition-temp.json'"
) else (
  REM Remove load balancer section
  powershell -Command "$json = Get-Content '!SERVICE_DEF_FILE!' | ConvertFrom-Json; $json.PSObject.Properties.Remove('loadBalancers'); $json.PSObject.Properties.Remove('healthCheckGracePeriodSeconds'); $json | ConvertTo-Json -Depth 10 | Set-Content '%TEMP%\service-definition-temp.json'"
  powershell -Command "(Get-Content '%TEMP%\service-definition-temp.json') -replace '{{CLUSTER_NAME}}', '!CLUSTER_NAME!' -replace '{{SUBNET_1}}', '!SUBNET_1!' -replace '{{SUBNET_2}}', '!SUBNET_2!' -replace '{{SECURITY_GROUP}}', '!SECURITY_GROUP!' | Set-Content '%TEMP%\service-definition-temp.json'"
)

REM Check if service exists
echo Checking if service exists...
for /f "delims=" %%i in ('aws ecs describe-services --cluster !CLUSTER_NAME! --services !SERVICE_NAME! --region !AWS_REGION! --query services[?status==`ACTIVE`].serviceName --output text 2^>nul') do set EXISTING_SERVICE=%%i

if not "!EXISTING_SERVICE!"=="" (
  echo Service exists. Updating service...
  aws ecs update-service --cluster !CLUSTER_NAME! --service !SERVICE_NAME! --task-definition !TASK_DEF_ARN! --force-new-deployment --region !AWS_REGION! >nul
  echo Service updated successfully
) else (
  echo Service does not exist. Creating service...
  aws ecs create-service --cli-input-json file://%TEMP%\service-definition-temp.json --region !AWS_REGION! >nul
  echo Service created successfully
)

del "%TEMP%\service-definition-temp.json"
echo.

REM Wait for service stability
echo Waiting for service to stabilize (this may take a few minutes)...
aws ecs wait services-stable --cluster !CLUSTER_NAME! --services !SERVICE_NAME! --region !AWS_REGION!
echo Service is stable
echo.

REM Verify deployment
echo Verifying deployment...
for /f "delims=" %%i in ('aws ecs describe-services --cluster !CLUSTER_NAME! --services !SERVICE_NAME! --region !AWS_REGION! --query services[0].runningCount --output text') do set RUNNING_COUNT=%%i
for /f "delims=" %%i in ('aws ecs describe-services --cluster !CLUSTER_NAME! --services !SERVICE_NAME! --region !AWS_REGION! --query services[0].desiredCount --output text') do set DESIRED_COUNT=%%i

echo ============================================
echo   Deployment Complete!
echo ============================================
echo.
echo Service Status:
echo   Cluster: !CLUSTER_NAME!
echo   Service: !SERVICE_NAME!
echo   Running Tasks: !RUNNING_COUNT!
echo   Desired Tasks: !DESIRED_COUNT!
echo.

if "!USE_LB!"=="true" (
  echo Load Balancer:
  echo   DNS Name: !ALB_DNS!
  echo   Access your application at: http://!ALB_DNS!
  echo.
)

echo CloudWatch Logs:
echo   Log Group: !LOG_GROUP!
echo   View logs: https://console.aws.amazon.com/cloudwatch/home?region=!AWS_REGION!#logsV2:log-groups/log-group=!LOG_GROUP!
echo.
echo ECS Console:
echo   https://console.aws.amazon.com/ecs/home?region=!AWS_REGION!#/clusters/!CLUSTER_NAME!/services/!SERVICE_NAME!
echo.

endlocal