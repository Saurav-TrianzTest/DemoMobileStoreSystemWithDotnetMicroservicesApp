# Deployment Guide: .NET 5.0 Microservices Application on AWS ECS Fargate

This guide provides comprehensive instructions for deploying the .NET 5.0 microservices application to AWS ECS Fargate.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Project Overview](#project-overview)
3. [Local Development Setup](#local-development-setup)
4. [Docker Deployment](#docker-deployment)
5. [AWS ECS Fargate Prerequisites](#aws-ecs-fargate-prerequisites)
6. [AWS ECS Fargate Setup](#aws-ecs-fargate-setup)
7. [Building and Pushing Images](#building-and-pushing-images)
8. [ECS Deployment](#ecs-deployment)
9. [Configuration Management](#configuration-management)
10. [Monitoring and Logging](#monitoring-and-logging)
11. [Troubleshooting](#troubleshooting)
12. [Scaling and Performance](#scaling-and-performance)
13. [Security Considerations](#security-considerations)

---

## Prerequisites

### Required Tools

- **.NET 5.0 SDK** or later
- **Docker Desktop** (for local development)
- **AWS CLI** v2 or later
- **Git** (for version control)
- **jq** (for JSON processing in scripts) - Linux/macOS only

### AWS Requirements

- AWS Account with appropriate permissions
- AWS CLI configured with credentials
- IAM roles for ECS task execution
- VPC with at least 2 subnets in different availability zones
- Security groups configured for container communication

### Required AWS Permissions

Your IAM user/role needs:
- `ecs:*` - ECS service management
- `ecr:*` - ECR repository management
- `iam:PassRole` - Pass execution role to ECS tasks
- `logs:*` - CloudWatch Logs
- `ec2:DescribeSubnets`, `ec2:DescribeSecurityGroups`, `ec2:DescribeVpcs`
- `elasticloadbalancing:*` - Application Load Balancer (if using load balancer)

---

## Project Overview

### Microservices Architecture

This application consists of 5 microservices:

1. **Catalog API** (`catalog-api`)
   - Port: 8001
   - Technology: ASP.NET Core 5.0
   - Database: MongoDB (external)
   - Purpose: Product catalog management

2. **Basket API** (`basket-api`)
   - Port: 8002
   - Technology: ASP.NET Core 5.0
   - Database: Redis (external)
   - Message Queue: RabbitMQ (external)
   - Purpose: Shopping basket management

3. **Ordering API** (`ordering-api`)
   - Port: 8003
   - Technology: ASP.NET Core 5.0
   - Database: SQL Server (external)
   - Message Queue: RabbitMQ (external)
   - Purpose: Order processing

4. **API Gateway** (`api-gateway`)
   - Port: 7000
   - Technology: ASP.NET Core 5.0 + Ocelot
   - Purpose: API Gateway and routing

5. **UI Layer** (`ui-layer`)
   - Port: 8000
   - Technology: ASP.NET Core 5.0 MVC
   - Purpose: Web frontend

### External Dependencies

The application requires the following external services (NOT included in containerization):
- MongoDB (for Catalog service)
- Redis (for Basket service)
- SQL Server (for Ordering service)
- RabbitMQ (for event-driven communication)

These should be provisioned separately on AWS:
- **MongoDB**: Use Amazon DocumentDB or MongoDB Atlas
- **Redis**: Use Amazon ElastiCache for Redis
- **SQL Server**: Use Amazon RDS for SQL Server
- **RabbitMQ**: Use Amazon MQ for RabbitMQ

---

## Local Development Setup

### 1. Clone the Repository

```bash
git clone <repository-url>
cd mcont
```

### 2. Install .NET Dependencies

```bash
dotnet restore
```

### 3. Build the Solution

```bash
dotnet build
```

### 4. Run Individual Services Locally

**Catalog API:**
```bash
cd src/catalog/Catalog.API
dotnet run
```

**Basket API:**
```bash
cd src/Basket/BasketAPI
dotnet run
```

**Ordering API:**
```bash
cd src/Ordering/Ordering
dotnet run
```

**API Gateway:**
```bash
cd src/ApiGateway/ApiGateway
dotnet run
```

**UI Layer:**
```bash
cd src/UI_Layer
dotnet run
```

### 5. Access Services

- Catalog API: http://localhost:8001
- Basket API: http://localhost:8002
- Ordering API: http://localhost:8003
- API Gateway: http://localhost:7000
- UI Layer: http://localhost:8000

---

## Docker Deployment

### Build Docker Images Locally

**Build Catalog API:**
```bash
docker build \
  -f Dockerfile \
  --build-arg PROJECT_PATH=src/catalog/Catalog.API \
  --build-arg PROJECT_NAME=Catalog.API \
  -t catalog-api:latest \
  .
```

**Build Basket API:**
```bash
docker build \
  -f Dockerfile \
  --build-arg PROJECT_PATH=src/Basket/BasketAPI \
  --build-arg PROJECT_NAME=BasketAPI \
  -t basket-api:latest \
  .
```

**Build Ordering API:**
```bash
docker build \
  -f Dockerfile \
  --build-arg PROJECT_PATH=src/Ordering/Ordering \
  --build-arg PROJECT_NAME=Ordering.API \
  -t ordering-api:latest \
  .
```

**Build API Gateway:**
```bash
docker build \
  -f Dockerfile \
  --build-arg PROJECT_PATH=src/ApiGateway/ApiGateway \
  --build-arg PROJECT_NAME=ApiGateway \
  -t api-gateway:latest \
  .
```

**Build UI Layer:**
```bash
docker build \
  -f Dockerfile \
  --build-arg PROJECT_PATH=src/UI_Layer \
  --build-arg PROJECT_NAME=AspnetRunBasics \
  -t ui-layer:latest \
  .
```

### Run with Docker Compose

```bash
# Set environment variables
export MONGODB_CONNECTION="mongodb://your-mongodb-host:27017"
export REDIS_HOST="your-redis-host:6379"
export RABBITMQ_HOST="your-rabbitmq-host"
export SQL_SERVER_HOST="your-sql-server-host"
export SQL_SERVER_PASSWORD="your-password"

# Start services
docker-compose up -d

# View logs
docker-compose logs -f

# Stop services
docker-compose down
```

---

## AWS ECS Fargate Prerequisites

### 1. Create IAM Roles

**ECS Task Execution Role:**

Create a role named `ecsTaskExecutionRole` with the following policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
```

**ECS Task Role (Optional):**

Create a role named `ecsTaskRole` for application-level AWS permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "*"
    }
  ]
}
```

### 2. Create VPC and Networking

**Create VPC:**
```bash
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --region us-east-1 \
  --query 'Vpc.VpcId' \
  --output text)
```

**Create Subnets:**
```bash
# Subnet 1 (AZ 1)
SUBNET_1=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 \
  --availability-zone us-east-1a \
  --region us-east-1 \
  --query 'Subnet.SubnetId' \
  --output text)

# Subnet 2 (AZ 2)
SUBNET_2=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.2.0/24 \
  --availability-zone us-east-1b \
  --region us-east-1 \
  --query 'Subnet.SubnetId' \
  --output text)
```

**Create Internet Gateway:**
```bash
IGW_ID=$(aws ec2 create-internet-gateway \
  --region us-east-1 \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

aws ec2 attach-internet-gateway \
  --vpc-id $VPC_ID \
  --internet-gateway-id $IGW_ID \
  --region us-east-1
```

**Create Route Table:**
```bash
ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --region us-east-1 \
  --query 'RouteTable.RouteTableId' \
  --output text)

aws ec2 create-route \
  --route-table-id $ROUTE_TABLE_ID \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID \
  --region us-east-1

aws ec2 associate-route-table \
  --route-table-id $ROUTE_TABLE_ID \
  --subnet-id $SUBNET_1 \
  --region us-east-1

aws ec2 associate-route-table \
  --route-table-id $ROUTE_TABLE_ID \
  --subnet-id $SUBNET_2 \
  --region us-east-1
```

**Create Security Group:**
```bash
SG_ID=$(aws ec2 create-security-group \
  --group-name microservices-sg \
  --description "Security group for microservices" \
  --vpc-id $VPC_ID \
  --region us-east-1 \
  --query 'GroupId' \
  --output text)

# Allow HTTP traffic
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  --region us-east-1

# Allow HTTPS traffic
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 443 \
  --cidr 0.0.0.0/0 \
  --region us-east-1

# Allow internal communication
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 0-65535 \
  --source-group $SG_ID \
  --region us-east-1
```

### 3. Create CloudWatch Log Group

```bash
aws logs create-log-group \
  --log-group-name /ecs/microservices-app \
  --region us-east-1
```

### 4. Provision External Services

**MongoDB (Amazon DocumentDB):**
```bash
aws docdb create-db-cluster \
  --db-cluster-identifier microservices-docdb \
  --engine docdb \
  --master-username admin \
  --master-user-password YourPassword123 \
  --vpc-security-group-ids $SG_ID \
  --db-subnet-group-name your-subnet-group \
  --region us-east-1
```

**Redis (Amazon ElastiCache):**
```bash
aws elasticache create-cache-cluster \
  --cache-cluster-id microservices-redis \
  --cache-node-type cache.t3.micro \
  --engine redis \
  --num-cache-nodes 1 \
  --security-group-ids $SG_ID \
  --region us-east-1
```

**SQL Server (Amazon RDS):**
```bash
aws rds create-db-instance \
  --db-instance-identifier microservices-sqlserver \
  --db-instance-class db.t3.small \
  --engine sqlserver-ex \
  --master-username admin \
  --master-user-password YourPassword123 \
  --allocated-storage 20 \
  --vpc-security-group-ids $SG_ID \
  --region us-east-1
```

**RabbitMQ (Amazon MQ):**
```bash
aws mq create-broker \
  --broker-name microservices-rabbitmq \
  --engine-type RABBITMQ \
  --engine-version 3.9.16 \
  --host-instance-type mq.t3.micro \
  --deployment-mode SINGLE_INSTANCE \
  --security-groups $SG_ID \
  --subnet-ids $SUBNET_1 \
  --users Username=admin,Password=YourPassword123 \
  --region us-east-1
```

---

## AWS ECS Fargate Setup

### Understanding ECS Fargate

AWS Fargate is a serverless compute engine for containers:
- **No EC2 instances to manage** - AWS manages infrastructure
- **Pay for what you use** - Charged based on vCPU and memory
- **Automatic scaling** - Scale containers independently
- **Built-in security** - Isolated compute environment

### Valid Fargate CPU/Memory Combinations

| CPU (vCPU) | Memory (MB) |
|------------|-------------|
| 256 (.25)  | 512, 1024, 2048 |
| 512 (.5)   | 1024, 2048, 3072, 4096 |
| 1024 (1)   | 2048-8192 (1GB increments) |
| 2048 (2)   | 4096-16384 (1GB increments) |
| 4096 (4)   | 8192-30720 (1GB increments) |

**Default Configuration:** CPU: 512, Memory: 1024 (good starting point)

### ECS Task Definition Explained

The task definition (`ecs/task-definition.json`) defines:

1. **Launch Type:** `FARGATE` (serverless)
2. **Network Mode:** `awsvpc` (required for Fargate)
3. **CPU/Memory:** Resource allocation
4. **Execution Role:** IAM role for ECS agent
5. **Container Definition:**
   - Image URI
   - Port mappings
   - Environment variables
   - Health checks
   - Logging configuration

### ECS Service Configuration

The service definition (`ecs/service-definition.json`) defines:

1. **Desired Count:** Number of running tasks (default: 2)
2. **Launch Type:** FARGATE
3. **Network Configuration:**
   - Subnets (multiple AZs for high availability)
   - Security groups
   - Public IP assignment
4. **Load Balancer:** Application Load Balancer integration
5. **Deployment Configuration:**
   - Rolling update strategy
   - Circuit breaker (automatic rollback)
6. **Auto Scaling:** (optional, configured separately)

---

## Building and Pushing Images

### Using build-push.sh (Linux/macOS)

```bash
chmod +x scripts/build-push.sh
./scripts/build-push.sh
```

**The script will:**
1. Prompt for registry type (ECR or Docker Hub)
2. Collect registry credentials
3. Authenticate with the registry
4. Build all microservice images
5. Push images to the registry

**Example Output:**
```
============================================
  Microservices Docker Build and Push
============================================

Select Docker Registry:
1. AWS ECR
2. Docker Hub
Enter choice (1 or 2): 1

Enter AWS Region (e.g., us-east-1): us-east-1
Enter AWS Account ID: 123456789012

Authenticating with AWS ECR...
ECR authentication successful

Enter image tag (default: latest): v1.0.0

Building and pushing microservices...

=== Building catalog-api ===
Project Path: src/catalog/Catalog.API
Project Name: Catalog.API
Image: 123456789012.dkr.ecr.us-east-1.amazonaws.com/catalog-api:v1.0.0

[Build output...]

✓ Successfully built and pushed catalog-api

[Continues for all services...]

============================================
  All microservices built and pushed!
============================================
```

### Using build-push.bat (Windows)

```cmd
scripts\build-push.bat
```

---

## ECS Deployment

### Using deploy-image.sh (Linux/macOS)

```bash
chmod +x scripts/deploy-image.sh
./scripts/deploy-image.sh
```

**The script will:**
1. Prompt for AWS configuration
2. Check/create ECS cluster
3. Optionally create Application Load Balancer
4. Replace placeholders in JSON files
5. Register task definition
6. Create or update ECS service
7. Wait for service stability
8. Display deployment status

**Example Deployment:**

```bash
./scripts/deploy-image.sh

# Prompts:
Enter AWS region (e.g., us-east-1): us-east-1
Enter ECS cluster name (e.g., microservices-cluster): microservices-cluster
Enter VPC ID (e.g., vpc-0abc123def456): vpc-0a1b2c3d4e5f
Enter Subnet IDs comma-separated (e.g., subnet-0abc123,subnet-0def456): subnet-111,subnet-222
Enter Security Group ID (e.g., sg-0abc123def): sg-0a1b2c3d
Enter Docker image URI (e.g., 123456789.dkr.ecr.us-east-1.amazonaws.com/app:latest): 123456789012.dkr.ecr.us-east-1.amazonaws.com/catalog-api:v1.0.0

Do you need a load balancer for this service? (y/n): y

# Script creates ALB and Target Group automatically
# Then deploys the service

============================================
  Deployment Complete!
============================================

Service Status:
  Cluster: microservices-cluster
  Service: microservices-app-service
  Running Tasks: 2
  Desired Tasks: 2

Load Balancer:
  DNS Name: microservices-alb-123456.us-east-1.elb.amazonaws.com
  Access your application at: http://microservices-alb-123456.us-east-1.elb.amazonaws.com

CloudWatch Logs:
  Log Group: /ecs/microservices-app
```

### Using deploy-image.bat (Windows)

```cmd
scripts\deploy-image.bat
```

### Manual Deployment (Alternative)

**1. Register Task Definition:**
```bash
aws ecs register-task-definition \
  --cli-input-json file://ecs/task-definition.json \
  --region us-east-1
```

**2. Create Service:**
```bash
aws ecs create-service \
  --cli-input-json file://ecs/service-definition.json \
  --region us-east-1
```

**3. Update Service (for redeploys):**
```bash
aws ecs update-service \
  --cluster microservices-cluster \
  --service microservices-app-service \
  --task-definition microservices-app-task:2 \
  --force-new-deployment \
  --region us-east-1
```

---

## Configuration Management

### Environment Variables

Update environment variables in `ecs/task-definition.json`:

```json
"environment": [
  {
    "name": "ASPNETCORE_ENVIRONMENT",
    "value": "Production"
  },
  {
    "name": "MONGODB_CONNECTION",
    "value": "mongodb://your-documentdb-endpoint:27017"
  },
  {
    "name": "REDIS_HOST",
    "value": "your-elasticache-endpoint:6379"
  },
  {
    "name": "SQL_SERVER_HOST",
    "value": "your-rds-endpoint"
  },
  {
    "name": "RABBITMQ_HOST",
    "value": "your-amazonmq-endpoint"
  }
]
```

### Using AWS Secrets Manager (Recommended)

Store sensitive data in Secrets Manager:

```bash
aws secretsmanager create-secret \
  --name microservices/database \
  --secret-string '{"username":"admin","password":"P@ssword123"}' \
  --region us-east-1
```

Reference in task definition:

```json
"secrets": [
  {
    "name": "DB_USERNAME",
    "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:microservices/database:username::"
  },
  {
    "name": "DB_PASSWORD",
    "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:microservices/database:password::"
  }
]
```

---

## Monitoring and Logging

### CloudWatch Logs

**View Logs:**
```bash
aws logs tail /ecs/microservices-app --follow --region us-east-1
```

**View Specific Log Stream:**
```bash
aws logs get-log-events \
  --log-group-name /ecs/microservices-app \
  --log-stream-name ecs/microservices-app/task-id \
  --region us-east-1
```

### CloudWatch Metrics

Monitor ECS metrics:
- CPU Utilization
- Memory Utilization
- Network In/Out
- Active Connections (if using ALB)

**Create CloudWatch Dashboard:**
```bash
aws cloudwatch put-dashboard \
  --dashboard-name microservices-dashboard \
  --dashboard-body file://dashboard.json \
  --region us-east-1
```

### Application Insights (Optional)

Add Application Insights to your .NET application:

```bash
dotnet add package Microsoft.ApplicationInsights.AspNetCore
```

Configure in `Startup.cs`:
```csharp
public void ConfigureServices(IServiceCollection services)
{
    services.AddApplicationInsightsTelemetry();
}
```

---

## Troubleshooting

### Common Issues

#### 1. Task Failed to Start

**Symptoms:** Tasks immediately stop after starting

**Diagnosis:**
```bash
aws ecs describe-tasks \
  --cluster microservices-cluster \
  --tasks task-id \
  --region us-east-1
```

**Common Causes:**
- Invalid CPU/memory combination
- Missing IAM permissions
- Image pull errors (ECR authentication)
- Application crashes on startup

**Solutions:**
- Verify CPU/memory in task definition
- Check execution role has ECR permissions
- Check CloudWatch logs for application errors

#### 2. Service Unstable

**Symptoms:** Tasks continuously restart

**Diagnosis:**
```bash
aws ecs describe-services \
  --cluster microservices-cluster \
  --services microservices-app-service \
  --region us-east-1
```

**Common Causes:**
- Health check failures
- Application crashes
- Insufficient resources
- Dependency service unavailable (MongoDB, Redis, etc.)

**Solutions:**
- Review health check configuration
- Check CloudWatch logs for errors
- Verify external service connectivity
- Increase CPU/memory allocation

#### 3. Unable to Pull Image

**Error:** `CannotPullContainerError`

**Solutions:**
- Verify image URI is correct
- Check execution role has ECR permissions:
  ```json
  {
    "Effect": "Allow",
    "Action": [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage"
    ],
    "Resource": "*"
  }
  ```
- Ensure image exists in ECR

#### 4. Network Connectivity Issues

**Symptoms:** Cannot connect to external services

**Solutions:**
- Verify security group allows outbound traffic
- Check subnet route tables have internet gateway route
- Ensure `assignPublicIp: ENABLED` for internet access
- Verify external service endpoints are accessible

#### 5. Load Balancer Health Checks Failing

**Symptoms:** Tasks marked unhealthy by ALB

**Solutions:**
- Verify health check path is correct (`/health`)
- Check application is listening on correct port (80)
- Increase health check grace period
- Review application logs for errors

### Debug Commands

**List Running Tasks:**
```bash
aws ecs list-tasks \
  --cluster microservices-cluster \
  --region us-east-1
```

**Describe Task:**
```bash
aws ecs describe-tasks \
  --cluster microservices-cluster \
  --tasks task-arn \
  --region us-east-1
```

**Check Service Events:**
```bash
aws ecs describe-services \
  --cluster microservices-cluster \
  --services microservices-app-service \
  --region us-east-1 \
  --query 'services[0].events'
```

**View Container Logs:**
```bash
aws logs tail /ecs/microservices-app \
  --follow \
  --format short \
  --region us-east-1
```

---

## Scaling and Performance

### Service Auto Scaling

**Create Auto Scaling Target:**
```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/microservices-cluster/microservices-app-service \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 2 \
  --max-capacity 10 \
  --region us-east-1
```

**Create Scaling Policy (CPU-based):**
```bash
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id service/microservices-cluster/microservices-app-service \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name cpu-scaling-policy \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration file://scaling-policy.json \
  --region us-east-1
```

**scaling-policy.json:**
```json
{
  "TargetValue": 70.0,
  "PredefinedMetricSpecification": {
    "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
  },
  "ScaleInCooldown": 300,
  "ScaleOutCooldown": 60
}
```

### Performance Optimization

**1. Right-size Resources:**
- Start with CPU: 512, Memory: 1024
- Monitor CloudWatch metrics
- Adjust based on actual usage

**2. Enable Container Insights:**
```bash
aws ecs put-account-setting \
  --name containerInsights \
  --value enabled \
  --region us-east-1
```

**3. Use Spot Capacity (for non-critical workloads):**
```json
"capacityProviderStrategy": [
  {
    "capacityProvider": "FARGATE_SPOT",
    "weight": 1
  }
]
```

**4. Optimize .NET Application:**
- Use ReadyToRun (R2R) images for faster startup
- Enable Server GC for better throughput
- Use response compression
- Implement caching strategies

### Blue/Green Deployments

**Using AWS CodeDeploy:**

1. Create CodeDeploy application:
```bash
aws deploy create-application \
  --application-name microservices-app \
  --compute-platform ECS \
  --region us-east-1
```

2. Create deployment group:
```bash
aws deploy create-deployment-group \
  --application-name microservices-app \
  --deployment-group-name microservices-dg \
  --service-role-arn arn:aws:iam::123456789012:role/CodeDeployRole \
  --deployment-config-name CodeDeployDefault.ECSAllAtOnce \
  --ecs-services clusterName=microservices-cluster,serviceName=microservices-app-service \
  --load-balancer-info targetGroupPairInfoList=[{targetGroups=[{name=blue-tg},{name=green-tg}],prodTrafficRoute={listenerArns=[arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/my-alb/...]}}] \
  --region us-east-1
```

---

## Security Considerations

### 1. Use Non-Root User in Containers

The Dockerfile already creates a non-root user:
```dockerfile
RUN groupadd -r appuser && useradd -r -g appuser appuser
USER appuser
```

### 2. Enable VPC Flow Logs

```bash
aws ec2 create-flow-logs \
  --resource-type VPC \
  --resource-ids $VPC_ID \
  --traffic-type ALL \
  --log-destination-type cloud-watch-logs \
  --log-group-name /aws/vpc/flowlogs \
  --region us-east-1
```

### 3. Use AWS Secrets Manager

Never hardcode credentials in task definitions. Use Secrets Manager or Parameter Store.

### 4. Enable ECS Task Role for Least Privilege

Grant only necessary permissions to task role:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::my-bucket/*"
    }
  ]
}
```

### 5. Use HTTPS with ALB

```bash
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTPS \
  --port 443 \
  --certificates CertificateArn=arn:aws:acm:us-east-1:123456789012:certificate/... \
  --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN \
  --region us-east-1
```

### 6. Enable AWS GuardDuty

```bash
aws guardduty create-detector \
  --enable \
  --region us-east-1
```

### 7. Scan Container Images

Enable ECR image scanning:
```bash
aws ecr put-image-scanning-configuration \
  --repository-name catalog-api \
  --image-scanning-configuration scanOnPush=true \
  --region us-east-1
```

---

## Useful Commands Reference

### ECS Commands

```bash
# List clusters
aws ecs list-clusters --region us-east-1

# List services
aws ecs list-services --cluster microservices-cluster --region us-east-1

# List tasks
aws ecs list-tasks --cluster microservices-cluster --region us-east-1

# Stop task
aws ecs stop-task --cluster microservices-cluster --task task-id --region us-east-1

# Update service
aws ecs update-service \
  --cluster microservices-cluster \
  --service microservices-app-service \
  --desired-count 4 \
  --region us-east-1

# Delete service
aws ecs delete-service \
  --cluster microservices-cluster \
  --service microservices-app-service \
  --force \
  --region us-east-1

# Delete cluster
aws ecs delete-cluster --cluster microservices-cluster --region us-east-1
```

### ECR Commands

```bash
# List repositories
aws ecr describe-repositories --region us-east-1

# List images
aws ecr list-images --repository-name catalog-api --region us-east-1

# Delete image
aws ecr batch-delete-image \
  --repository-name catalog-api \
  --image-ids imageTag=v1.0.0 \
  --region us-east-1

# Delete repository
aws ecr delete-repository \
  --repository-name catalog-api \
  --force \
  --region us-east-1
```

### CloudWatch Logs Commands

```bash
# List log groups
aws logs describe-log-groups --region us-east-1

# List log streams
aws logs describe-log-streams \
  --log-group-name /ecs/microservices-app \
  --region us-east-1

# Tail logs
aws logs tail /ecs/microservices-app --follow --region us-east-1

# Delete log group
aws logs delete-log-group \
  --log-group-name /ecs/microservices-app \
  --region us-east-1
```

---

## Additional Resources

- [AWS ECS Documentation](https://docs.aws.amazon.com/ecs/)
- [AWS Fargate Documentation](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html)
- [.NET on AWS](https://aws.amazon.com/developer/language/net/)
- [ASP.NET Core Best Practices](https://docs.microsoft.com/en-us/aspnet/core/fundamentals/best-practices)
- [Docker Best Practices](https://docs.docker.com/develop/dev-best-practices/)

---

## Support

For issues or questions:
1. Check CloudWatch logs for application errors
2. Review ECS service events
3. Consult AWS documentation
4. Contact your DevOps team

---

**Generated by Claude Code - .NET Containerization Expert**