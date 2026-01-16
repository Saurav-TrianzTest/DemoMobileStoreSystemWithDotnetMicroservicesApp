#!/bin/bash
set -e
set -o pipefail

echo "============================================"
echo "  AWS ECS Fargate Deployment"
echo "============================================"
echo ""

# Check prerequisites
if ! command -v aws &> /dev/null; then
  echo "ERROR: aws-cli is not installed"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "ERROR: jq is not installed"
  exit 1
fi

# Collect deployment parameters
read -p "Enter AWS region (e.g., us-east-1): " AWS_REGION
read -p "Enter ECS cluster name (e.g., microservices-cluster): " CLUSTER_NAME
read -p "Enter VPC ID (e.g., vpc-0abc123def456): " VPC_ID
read -p "Enter Subnet IDs comma-separated (e.g., subnet-0abc123,subnet-0def456): " SUBNETS_INPUT
read -p "Enter Security Group ID (e.g., sg-0abc123def): " SECURITY_GROUP
read -p "Enter Docker image URI (e.g., 123456789.dkr.ecr.us-east-1.amazonaws.com/app:latest): " IMAGE_URI

# Parse subnets
IFS=',' read -ra SUBNETS <<< "$SUBNETS_INPUT"
SUBNET_1="${SUBNETS[0]}"
SUBNET_2="${SUBNETS[1]:-$SUBNET_1}"

echo ""
echo "Deployment Configuration:"
echo "  Region: $AWS_REGION"
echo "  Cluster: $CLUSTER_NAME"
echo "  VPC: $VPC_ID"
echo "  Subnets: $SUBNET_1, $SUBNET_2"
echo "  Security Group: $SECURITY_GROUP"
echo "  Image: $IMAGE_URI"
echo ""

# Get AWS Account ID
echo "Retrieving AWS Account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ID: $ACCOUNT_ID"
echo ""

# Check/Create ECS Cluster
echo "Checking ECS cluster..."
if aws ecs describe-clusters --clusters "$CLUSTER_NAME" --region "$AWS_REGION" 2>/dev/null | grep -q "$CLUSTER_NAME"; then
  echo "Cluster $CLUSTER_NAME exists"
else
  echo "Creating ECS cluster: $CLUSTER_NAME"
  aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION"
fi
echo ""

# Load Balancer configuration
read -p "Do you need a load balancer for this service? (y/n): " NEED_LB

if [[ "$NEED_LB" =~ ^[Yy]$ ]]; then
  echo ""
  echo "Creating Application Load Balancer and Target Group..."
  
  # Create ALB
  ALB_NAME="microservices-alb-$(date +%s)"
  echo "Creating ALB: $ALB_NAME"
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "$ALB_NAME" \
    --subnets "$SUBNET_1" "$SUBNET_2" \
    --security-groups "$SECURITY_GROUP" \
    --scheme internet-facing \
    --type application \
    --region "$AWS_REGION" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text)
  
  echo "ALB created: $ALB_ARN"
  
  # Get ALB DNS name
  ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" \
    --region "$AWS_REGION" \
    --query 'LoadBalancers[0].DNSName' \
    --output text)
  
  # Create Target Group with ip target type for Fargate
  TG_NAME="microservices-tg-$(date +%s)"
  echo "Creating Target Group: $TG_NAME"
  TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
    --name "$TG_NAME" \
    --protocol HTTP \
    --port 80 \
    --vpc-id "$VPC_ID" \
    --target-type ip \
    --health-check-path "/health" \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --region "$AWS_REGION" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)
  
  echo "Target Group created: $TARGET_GROUP_ARN"
  
  # Create Listener
  echo "Creating ALB Listener..."
  aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn="$TARGET_GROUP_ARN" \
    --region "$AWS_REGION" > /dev/null
  
  echo "Listener created successfully"
  echo ""
  
  USE_LB="true"
else
  echo "Skipping load balancer configuration"
  USE_LB="false"
fi

echo ""
echo "Creating CloudWatch Log Group..."
LOG_GROUP="/ecs/microservices-app"
aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$AWS_REGION" 2>/dev/null || echo "Log group already exists"
echo ""

# Prepare task definition
echo "Preparing task definition..."
TASK_DEF_FILE="ecs/task-definition.json"

if [ ! -f "$TASK_DEF_FILE" ]; then
  echo "ERROR: Task definition file not found: $TASK_DEF_FILE"
  exit 1
fi

# Replace placeholders
cp "$TASK_DEF_FILE" "/tmp/task-definition-$$.json"
sed -i "s|{{IMAGE_URI}}|$IMAGE_URI|g" "/tmp/task-definition-$$.json"
sed -i "s|{{AWS_REGION}}|$AWS_REGION|g" "/tmp/task-definition-$$.json"
sed -i "s|{{ACCOUNT_ID}}|$ACCOUNT_ID|g" "/tmp/task-definition-$$.json"

echo "Registering task definition..."
TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json file:///tmp/task-definition-$$.json \
  --region "$AWS_REGION" \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

echo "Task definition registered: $TASK_DEF_ARN"
rm "/tmp/task-definition-$$.json"
echo ""

# Prepare service definition
echo "Preparing service definition..."
SERVICE_DEF_FILE="ecs/service-definition.json"
SERVICE_NAME="microservices-app-service"

if [ ! -f "$SERVICE_DEF_FILE" ]; then
  echo "ERROR: Service definition file not found: $SERVICE_DEF_FILE"
  exit 1
fi

# Replace placeholders
cp "$SERVICE_DEF_FILE" "/tmp/service-definition-$$.json"
sed -i "s|{{CLUSTER_NAME}}|$CLUSTER_NAME|g" "/tmp/service-definition-$$.json"
sed -i "s|{{SUBNET_1}}|$SUBNET_1|g" "/tmp/service-definition-$$.json"
sed -i "s|{{SUBNET_2}}|$SUBNET_2|g" "/tmp/service-definition-$$.json"
sed -i "s|{{SECURITY_GROUP}}|$SECURITY_GROUP|g" "/tmp/service-definition-$$.json"

if [ "$USE_LB" = "true" ]; then
  sed -i "s|{{TARGET_GROUP_ARN}}|$TARGET_GROUP_ARN|g" "/tmp/service-definition-$$.json"
else
  # Remove loadBalancers section if no LB
  jq 'del(.loadBalancers, .healthCheckGracePeriodSeconds)' "/tmp/service-definition-$$.json" > "/tmp/service-definition-no-lb-$$.json"
  mv "/tmp/service-definition-no-lb-$$.json" "/tmp/service-definition-$$.json"
fi

# Check if service exists
echo "Checking if service exists..."
EXISTING_SERVICE=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --region "$AWS_REGION" \
  --query 'services[?status==`ACTIVE`].serviceName' \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_SERVICE" ]; then
  echo "Service exists. Updating service..."
  aws ecs update-service \
    --cluster "$CLUSTER_NAME" \
    --service "$SERVICE_NAME" \
    --task-definition "$TASK_DEF_ARN" \
    --force-new-deployment \
    --region "$AWS_REGION" > /dev/null
  
  echo "Service updated successfully"
else
  echo "Service does not exist. Creating service..."
  aws ecs create-service \
    --cli-input-json file:///tmp/service-definition-$$.json \
    --region "$AWS_REGION" > /dev/null
  
  echo "Service created successfully"
fi

rm "/tmp/service-definition-$$.json"
echo ""

# Wait for service stability
echo "Waiting for service to stabilize (this may take a few minutes)..."
aws ecs wait services-stable \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --region "$AWS_REGION"

echo "Service is stable"
echo ""

# Verify deployment
echo "Verifying deployment..."
SERVICE_INFO=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --region "$AWS_REGION" \
  --query 'services[0]' \
  --output json)

RUNNING_COUNT=$(echo "$SERVICE_INFO" | jq -r '.runningCount')
DESIRED_COUNT=$(echo "$SERVICE_INFO" | jq -r '.desiredCount')

echo "============================================"
echo "  Deployment Complete!"
echo "============================================"
echo ""
echo "Service Status:"
echo "  Cluster: $CLUSTER_NAME"
echo "  Service: $SERVICE_NAME"
echo "  Running Tasks: $RUNNING_COUNT"
echo "  Desired Tasks: $DESIRED_COUNT"
echo ""

if [ "$USE_LB" = "true" ]; then
  echo "Load Balancer:"
  echo "  DNS Name: $ALB_DNS"
  echo "  Access your application at: http://$ALB_DNS"
  echo ""
fi

echo "CloudWatch Logs:"
echo "  Log Group: $LOG_GROUP"
echo "  View logs: https://console.aws.amazon.com/cloudwatch/home?region=$AWS_REGION#logsV2:log-groups/log-group/$LOG_GROUP"
echo ""
echo "ECS Console:"
echo "  https://console.aws.amazon.com/ecs/home?region=$AWS_REGION#/clusters/$CLUSTER_NAME/services/$SERVICE_NAME"
echo ""
