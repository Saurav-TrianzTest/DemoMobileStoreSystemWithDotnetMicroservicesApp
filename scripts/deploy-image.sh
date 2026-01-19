#!/bin/bash
set -e
set -o pipefail

# Script to deploy Docker image to AWS ECS Fargate

echo "=========================================="
echo "AWS ECS Fargate Deployment Script"
echo "=========================================="
echo ""

# Configuration
PROJECT_NAME="dmstcont"
TASK_FAMILY="${PROJECT_NAME}-task"
SERVICE_NAME="${PROJECT_NAME}-service"

TASK_DEF_FILE="ecs/task-definition.json"
SERVICE_DEF_FILE="ecs/service-definition.json"

# Prompt for AWS configuration
echo "AWS Configuration"
echo "-----------------"
read -p "Enter AWS region (e.g., us-east-1): " AWS_REGION
read -p "Enter ECS cluster name (e.g., my-ecs-cluster): " CLUSTER_NAME
echo ""

# Set AWS region
export AWS_DEFAULT_REGION="$AWS_REGION"

# Get AWS Account ID
echo "Retrieving AWS Account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

if [ -z "$ACCOUNT_ID" ]; then
    echo "Error: Failed to retrieve AWS Account ID. Check AWS CLI configuration."
    exit 1
fi

echo "AWS Account ID: $ACCOUNT_ID"
echo ""

# Network Configuration
echo "Network Configuration"
echo "---------------------"
read -p "Enter VPC ID (e.g., vpc-0abc123def456): " VPC_ID
read -p "Enter Subnet IDs comma-separated (e.g., subnet-0abc123,subnet-0def456): " SUBNET_IDS
read -p "Enter Security Group ID (e.g., sg-0abc123def): " SECURITY_GROUP
echo ""

# Convert comma-separated subnets to array
IFS=',' read -ra SUBNETS <<< "$SUBNET_IDS"
SUBNET_1="${SUBNETS[0]}"
SUBNET_2="${SUBNETS[1]:-$SUBNET_1}"

# Docker Image Configuration
echo "Docker Image Configuration"
echo "---------------------------"
read -p "Enter Docker image URI (e.g., 123456789.dkr.ecr.us-east-1.amazonaws.com/dmstcont:latest): " IMAGE_URI
echo ""

# Check/create ECS cluster
echo "Checking ECS cluster..."
aws ecs describe-clusters --clusters "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || {
    echo "Cluster does not exist. Creating ECS cluster..."
    aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION"
    echo "Cluster created successfully"
}
echo ""

# Load Balancer Configuration
read -p "Do you need a load balancer for this service? (y/n): " USE_LB
echo ""

if [ "$USE_LB" = "y" ] || [ "$USE_LB" = "Y" ]; then
    echo "Creating Application Load Balancer and Target Group..."
    
    # Create ALB
    ALB_NAME="${PROJECT_NAME}-alb"
    echo "Creating ALB: $ALB_NAME"
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name "$ALB_NAME" \
        --subnets $SUBNET_1 $SUBNET_2 \
        --security-groups "$SECURITY_GROUP" \
        --scheme internet-facing \
        --type application \
        --ip-address-type ipv4 \
        --region "$AWS_REGION" \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$ALB_ARN" ]; then
        echo "ALB may already exist or creation failed. Attempting to describe existing ALB..."
        ALB_ARN=$(aws elbv2 describe-load-balancers \
            --names "$ALB_NAME" \
            --region "$AWS_REGION" \
            --query 'LoadBalancers[0].LoadBalancerArn' \
            --output text 2>/dev/null || echo "")
    fi
    
    if [ -z "$ALB_ARN" ]; then
        echo "Error: Failed to create or find ALB"
        exit 1
    fi
    
    echo "ALB ARN: $ALB_ARN"
    
    # Create Target Group with target-type ip (required for Fargate)
    TG_NAME="${PROJECT_NAME}-tg"
    echo "Creating Target Group: $TG_NAME"
    TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
        --name "$TG_NAME" \
        --protocol HTTP \
        --port 80 \
        --vpc-id "$VPC_ID" \
        --target-type ip \
        --health-check-enabled \
        --health-check-protocol HTTP \
        --health-check-path /health \
        --health-check-interval-seconds 30 \
        --health-check-timeout-seconds 5 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --region "$AWS_REGION" \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$TARGET_GROUP_ARN" ]; then
        echo "Target Group may already exist. Attempting to describe existing Target Group..."
        TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups \
            --names "$TG_NAME" \
            --region "$AWS_REGION" \
            --query 'TargetGroups[0].TargetGroupArn' \
            --output text 2>/dev/null || echo "")
    fi
    
    if [ -z "$TARGET_GROUP_ARN" ]; then
        echo "Error: Failed to create or find Target Group"
        exit 1
    fi
    
    echo "Target Group ARN: $TARGET_GROUP_ARN"
    
    # Create Listener
    echo "Creating ALB Listener..."
    aws elbv2 create-listener \
        --load-balancer-arn "$ALB_ARN" \
        --protocol HTTP \
        --port 80 \
        --default-actions Type=forward,TargetGroupArn="$TARGET_GROUP_ARN" \
        --region "$AWS_REGION" >/dev/null 2>&1 || echo "Listener may already exist"
    
    echo "Load Balancer setup completed"
    echo ""
    
    # Update service definition with load balancer
    jq --arg tg "$TARGET_GROUP_ARN" \
       '.loadBalancers[0].targetGroupArn = $tg | .healthCheckGracePeriodSeconds = 300' \
       "$SERVICE_DEF_FILE" > "${SERVICE_DEF_FILE}.tmp" && mv "${SERVICE_DEF_FILE}.tmp" "$SERVICE_DEF_FILE"
else
    echo "Skipping load balancer configuration"
    # Remove loadBalancers section from service definition
    jq 'del(.loadBalancers) | del(.healthCheckGracePeriodSeconds)' \
       "$SERVICE_DEF_FILE" > "${SERVICE_DEF_FILE}.tmp" && mv "${SERVICE_DEF_FILE}.tmp" "$SERVICE_DEF_FILE"
    echo ""
fi

# Create CloudWatch Log Group
echo "Creating CloudWatch Log Group..."
LOG_GROUP="/ecs/${PROJECT_NAME}"
aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$AWS_REGION" 2>/dev/null || echo "Log group already exists"
echo ""

# Replace placeholders in task definition
echo "Preparing task definition..."
cp "$TASK_DEF_FILE" "${TASK_DEF_FILE}.tmp"
sed -i "s|{{IMAGE_URI}}|${IMAGE_URI}|g" "${TASK_DEF_FILE}.tmp"
sed -i "s|{{AWS_REGION}}|${AWS_REGION}|g" "${TASK_DEF_FILE}.tmp"
sed -i "s|{{ACCOUNT_ID}}|${ACCOUNT_ID}|g" "${TASK_DEF_FILE}.tmp"

# Register task definition
echo "Registering ECS task definition..."
TASK_DEF_ARN=$(aws ecs register-task-definition \
    --cli-input-json file://${TASK_DEF_FILE}.tmp \
    --region "$AWS_REGION" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

if [ -z "$TASK_DEF_ARN" ]; then
    echo "Error: Failed to register task definition"
    rm -f "${TASK_DEF_FILE}.tmp"
    exit 1
fi

echo "Task Definition ARN: $TASK_DEF_ARN"
rm -f "${TASK_DEF_FILE}.tmp"
echo ""

# Replace placeholders in service definition
echo "Preparing service definition..."
cp "$SERVICE_DEF_FILE" "${SERVICE_DEF_FILE}.tmp"
sed -i "s|{{CLUSTER_NAME}}|${CLUSTER_NAME}|g" "${SERVICE_DEF_FILE}.tmp"
sed -i "s|{{SUBNET_1}}|${SUBNET_1}|g" "${SERVICE_DEF_FILE}.tmp"
sed -i "s|{{SUBNET_2}}|${SUBNET_2}|g" "${SERVICE_DEF_FILE}.tmp"
sed -i "s|{{SECURITY_GROUP}}|${SECURITY_GROUP}|g" "${SERVICE_DEF_FILE}.tmp"

# Check if service exists
echo "Checking if service exists..."
EXISTING_SERVICE=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$AWS_REGION" \
    --query 'services[?status==`ACTIVE`].serviceName' \
    --output text 2>/dev/null || echo "")

if [ -z "$EXISTING_SERVICE" ] || [ "$EXISTING_SERVICE" = "None" ]; then
    echo "Service does not exist. Creating new service..."
    aws ecs create-service \
        --cli-input-json file://${SERVICE_DEF_FILE}.tmp \
        --region "$AWS_REGION" >/dev/null
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create service"
        rm -f "${SERVICE_DEF_FILE}.tmp"
        exit 1
    fi
    
    echo "Service created successfully"
else
    echo "Service exists. Updating service..."
    aws ecs update-service \
        --cluster "$CLUSTER_NAME" \
        --service "$SERVICE_NAME" \
        --task-definition "$TASK_DEF_ARN" \
        --force-new-deployment \
        --region "$AWS_REGION" >/dev/null
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to update service"
        rm -f "${SERVICE_DEF_FILE}.tmp"
        exit 1
    fi
    
    echo "Service updated successfully"
fi

rm -f "${SERVICE_DEF_FILE}.tmp"
echo ""

# Wait for service stability
echo "Waiting for service to stabilize (this may take several minutes)..."
aws ecs wait services-stable \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$AWS_REGION"

if [ $? -ne 0 ]; then
    echo "Warning: Service did not stabilize within the expected time"
    echo "Check the ECS console for service status"
else
    echo "Service is stable"
fi
echo ""

# Verify deployment
echo "Verifying deployment..."
SERVICE_INFO=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$AWS_REGION" \
    --query 'services[0]')

RUNNING_COUNT=$(echo "$SERVICE_INFO" | jq -r '.runningCount')
DESIRED_COUNT=$(echo "$SERVICE_INFO" | jq -r '.desiredCount')

echo "Service Status:"
echo "  Running Tasks: $RUNNING_COUNT"
echo "  Desired Tasks: $DESIRED_COUNT"
echo ""

if [ "$USE_LB" = "y" ] || [ "$USE_LB" = "Y" ]; then
    ALB_DNS=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns "$ALB_ARN" \
        --region "$AWS_REGION" \
        --query 'LoadBalancers[0].DNSName' \
        --output text)
    
    echo "Application URL: http://$ALB_DNS"
    echo ""
fi

echo "CloudWatch Logs: $LOG_GROUP"
echo ""

echo "=========================================="
echo "Deployment Completed Successfully"
echo "=========================================="
echo ""
echo "Troubleshooting:"
echo "- View logs: aws logs tail $LOG_GROUP --follow --region $AWS_REGION"
echo "- List tasks: aws ecs list-tasks --cluster $CLUSTER_NAME --service-name $SERVICE_NAME --region $AWS_REGION"
echo "- Describe service: aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION"
echo ""