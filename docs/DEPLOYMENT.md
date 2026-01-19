# DMSTCont - AWS ECS Fargate Deployment Guide

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Local Development Setup](#local-development-setup)
4. [Docker Deployment](#docker-deployment)
5. [AWS ECS Fargate Prerequisites](#aws-ecs-fargate-prerequisites)
6. [ECS Fargate Setup](#ecs-fargate-setup)
7. [Building and Pushing Images](#building-and-pushing-images)
8. [ECS Task Definition](#ecs-task-definition)
9. [ECS Service Configuration](#ecs-service-configuration)
10. [Deployment Walkthrough](#deployment-walkthrough)
11. [Configuration Management](#configuration-management)
12. [Monitoring and Logging](#monitoring-and-logging)
13. [Troubleshooting](#troubleshooting)
14. [Scaling and Management](#scaling-and-management)
15. [Security Considerations](#security-considerations)
16. [.NET-Specific Considerations](#net-specific-considerations)

---

## Overview

This guide provides comprehensive instructions for deploying the DMSTCont .NET 5.0 application to AWS ECS Fargate. The application is containerized using Docker and deployed to a fully managed container orchestration platform.

### Technology Stack

- **Framework**: .NET 5.0 (ASP.NET Core)
- **Build Tool**: dotnet CLI
- **Container Runtime**: Docker
- **Orchestration**: AWS ECS Fargate
- **Load Balancer**: Application Load Balancer (ALB)
- **Logging**: AWS CloudWatch Logs

---

## Prerequisites

### Required Software

1. **Docker Desktop** (for local development)
   - Windows: Docker Desktop 4.0+
   - Linux: Docker Engine 20.10+
   - macOS: Docker Desktop 4.0+

2. **AWS CLI** (version 2.x)
   ```bash
   # Install AWS CLI v2
   # Linux/macOS
   curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
   unzip awscliv2.zip
   sudo ./aws/install
   
   # Windows
   # Download and run: https://awscli.amazonaws.com/AWSCLIV2.msi
   
   # Verify installation
   aws --version
   ```

3. **.NET 5.0 SDK** (for local development)
   ```bash
   # Verify installation
   dotnet --version
   ```

4. **jq** (JSON processor for scripts)
   ```bash
   # Linux
   sudo apt-get install jq
   
   # macOS
   brew install jq
   
   # Windows
   # Download from: https://stedolan.github.io/jq/download/
   ```

### AWS Account Requirements

- Active AWS account with appropriate permissions
- IAM user with the following permissions:
  - ECS full access
  - ECR full access
  - VPC and networking permissions
  - CloudWatch Logs access
  - IAM role creation (for task execution role)
  - Application Load Balancer permissions

### AWS CLI Configuration

```bash
# Configure AWS CLI with your credentials
aws configure

# Enter:
# - AWS Access Key ID
# - AWS Secret Access Key
# - Default region (e.g., us-east-1)
# - Default output format (json)

# Verify configuration
aws sts get-caller-identity
```

---

## Local Development Setup

### Running Locally with .NET

```bash
# Navigate to project directory
cd /modernize-data/studio-data/TNT1001/APP2954/transformed-code/1000/studio-workspace/DMSTCont

# Restore dependencies
dotnet restore

# Build the application
dotnet build -c Release

# Run the application
dotnet run

# Application will be available at http://localhost:80
```

### Running Locally with Docker

```bash
# Build Docker image
docker build -t dmstcont:local .

# Run container
docker run -p 80:80 \
  -e ASPNETCORE_ENVIRONMENT=Development \
  -e ASPNETCORE_URLS=http://+:80 \
  dmstcont:local

# Access application at http://localhost:80
```

### Using Docker Compose

```bash
# Start application
docker-compose up -d

# View logs
docker-compose logs -f

# Stop application
docker-compose down
```

---

## Docker Deployment

### Building the Docker Image

The Dockerfile uses a multi-stage build optimized for .NET applications:

1. **Builder Stage**: Uses `mcr.microsoft.com/dotnet/sdk:5.0` to build the application
2. **Publisher Stage**: Publishes the application to `/app/publish`
3. **Runtime Stage**: Uses `mcr.microsoft.com/dotnet/runtime:5.0` for minimal runtime image

```bash
# Build image
docker build -t dmstcont:latest .

# Verify image
docker images | grep dmstcont
```

### Testing the Container

```bash
# Run container
docker run -d -p 80:80 --name dmstcont-test dmstcont:latest

# Check logs
docker logs dmstcont-test

# Test health endpoint
curl http://localhost:80/health

# Stop and remove
docker stop dmstcont-test
docker rm dmstcont-test
```

---

## AWS ECS Fargate Prerequisites

### 1. Create IAM Roles

#### Task Execution Role

```bash
# Create trust policy file
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create role
aws iam create-role \
  --role-name ecsTaskExecutionRole \
  --assume-role-policy-document file://trust-policy.json

# Attach policy
aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
```

#### Task Role (Optional - for application AWS permissions)

```bash
# Create task role
aws iam create-role \
  --role-name ecsTaskRole \
  --assume-role-policy-document file://trust-policy.json

# Attach policies as needed (e.g., S3 access, DynamoDB, etc.)
```

### 2. Network Configuration

#### VPC and Subnets

```bash
# List available VPCs
aws ec2 describe-vpcs --query 'Vpcs[*].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' --output table

# List subnets in a VPC
aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-xxxxx" --query 'Subnets[*].[SubnetId,CidrBlock,AvailabilityZone]' --output table

# You need at least 2 subnets in different availability zones for Fargate
```

#### Security Group

```bash
# Create security group
aws ec2 create-security-group \
  --group-name dmstcont-sg \
  --description "Security group for DMSTCont ECS service" \
  --vpc-id vpc-xxxxx

# Add inbound rule for HTTP (port 80)
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxx \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0

# Add inbound rule for HTTPS (port 443) if needed
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxx \
  --protocol tcp \
  --port 443 \
  --cidr 0.0.0.0/0
```

### 3. ECR Repository

```bash
# Create ECR repository
aws ecr create-repository --repository-name dmstcont --region us-east-1

# Get repository URI
aws ecr describe-repositories --repository-names dmstcont --query 'repositories[0].repositoryUri' --output text
```

---

## ECS Fargate Setup

### 1. Create ECS Cluster

```bash
# Create Fargate cluster
aws ecs create-cluster --cluster-name dmstcont-cluster --region us-east-1

# Verify cluster
aws ecs describe-clusters --clusters dmstcont-cluster
```

### 2. CloudWatch Log Group

```bash
# Create log group
aws logs create-log-group --log-group-name /ecs/dmstcont --region us-east-1

# Set retention policy (optional - 7 days)
aws logs put-retention-policy \
  --log-group-name /ecs/dmstcont \
  --retention-in-days 7
```

---

## Building and Pushing Images

### Using the build-push Script

#### Linux/macOS

```bash
# Make script executable
chmod +x scripts/build-push.sh

# Run script
./scripts/build-push.sh

# Follow prompts:
# 1. Select registry (ECR or Docker Hub)
# 2. Enter registry details
# 3. Enter image tag (or use default 'latest')
```

#### Windows

```cmd
REM Run batch script
scripts\build-push.bat

REM Follow prompts:
REM 1. Select registry (ECR or Docker Hub)
REM 2. Enter registry details
REM 3. Enter image tag (or use default 'latest')
```

### Manual Build and Push

#### To AWS ECR

```bash
# Set variables
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="123456789012"
REPO_NAME="dmstcont"
IMAGE_TAG="latest"

# Authenticate with ECR
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Build image
docker build -t $REPO_NAME:$IMAGE_TAG .

# Tag image
docker tag $REPO_NAME:$IMAGE_TAG $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO_NAME:$IMAGE_TAG

# Push image
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO_NAME:$IMAGE_TAG
```

---

## ECS Task Definition

### Understanding the Task Definition

The task definition (`ecs/task-definition.json`) specifies:

- **Launch Type**: FARGATE (serverless)
- **Network Mode**: awsvpc (required for Fargate)
- **CPU**: 512 (.5 vCPU)
- **Memory**: 1024 MB (1 GB)
- **Container Configuration**:
  - Image URI
  - Port mappings (80)
  - Environment variables
  - Logging configuration

### Valid Fargate CPU/Memory Combinations

| CPU (Units) | Memory (MB) |
|-------------|-------------|
| 256 (.25 vCPU) | 512, 1024, 2048 |
| 512 (.5 vCPU) | 1024, 2048, 3072, 4096 |
| 1024 (1 vCPU) | 2048-8192 (increments of 1024) |
| 2048 (2 vCPU) | 4096-16384 (increments of 1024) |
| 4096 (4 vCPU) | 8192-30720 (increments of 1024) |

### Customizing Resources

Edit `ecs/task-definition.json`:

```json
{
  "cpu": "1024",
  "memory": "2048",
  ...
}
```

---

## ECS Service Configuration

### Understanding the Service Definition

The service definition (`ecs/service-definition.json`) specifies:

- **Service Name**: dmstcont-service
- **Desired Count**: 2 (number of tasks)
- **Launch Type**: FARGATE
- **Network Configuration**: Subnets, security groups, public IP
- **Deployment Configuration**: Rolling update settings
- **Load Balancer**: ALB integration (optional)

### Service Scaling

Modify `desiredCount` in service definition:

```json
{
  "desiredCount": 4,
  ...
}
```

---

## Deployment Walkthrough

### Step 1: Build and Push Image

```bash
# Run build-push script
./scripts/build-push.sh

# Note the image URI output (needed for deployment)
# Example: 123456789012.dkr.ecr.us-east-1.amazonaws.com/dmstcont:latest
```

### Step 2: Deploy to ECS

```bash
# Run deployment script
./scripts/deploy-image.sh

# Follow prompts:
# 1. AWS region (e.g., us-east-1)
# 2. ECS cluster name (e.g., dmstcont-cluster)
# 3. VPC ID
# 4. Subnet IDs (comma-separated)
# 5. Security group ID
# 6. Docker image URI
# 7. Load balancer (y/n)
```

### Step 3: Verify Deployment

```bash
# Check service status
aws ecs describe-services \
  --cluster dmstcont-cluster \
  --services dmstcont-service \
  --region us-east-1

# List running tasks
aws ecs list-tasks \
  --cluster dmstcont-cluster \
  --service-name dmstcont-service \
  --region us-east-1

# View task details
aws ecs describe-tasks \
  --cluster dmstcont-cluster \
  --tasks <task-arn> \
  --region us-east-1
```

### Step 4: Access Application

If load balancer was configured:

```bash
# Get ALB DNS name
aws elbv2 describe-load-balancers \
  --names dmstcont-alb \
  --query 'LoadBalancers[0].DNSName' \
  --output text

# Access application
# http://<alb-dns-name>
```

Without load balancer:

```bash
# Get task public IP
aws ecs describe-tasks \
  --cluster dmstcont-cluster \
  --tasks <task-arn> \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' \
  --output text

# Get public IP from network interface
aws ec2 describe-network-interfaces \
  --network-interface-ids <eni-id> \
  --query 'NetworkInterfaces[0].Association.PublicIp' \
  --output text
```

---

## Configuration Management

### Environment Variables

Environment variables are defined in the task definition:

```json
"environment": [
  {"name": "ASPNETCORE_ENVIRONMENT", "value": "Production"},
  {"name": "ASPNETCORE_URLS", "value": "http://+:80"}
]
```

### Using AWS Secrets Manager

For sensitive configuration:

```bash
# Create secret
aws secretsmanager create-secret \
  --name dmstcont/db-connection \
  --secret-string '{"ConnectionString":"Server=...;Database=..."}'

# Update task definition to reference secret
"secrets": [
  {
    "name": "ConnectionStrings__DefaultConnection",
    "valueFrom": "arn:aws:secretsmanager:region:account-id:secret:dmstcont/db-connection"
  }
]
```

### Configuration Files

Mount configuration files using EFS or build into image:

```dockerfile
# In Dockerfile
COPY appsettings.Production.json /app/
```

---

## Monitoring and Logging

### CloudWatch Logs

```bash
# View logs in real-time
aws logs tail /ecs/dmstcont --follow --region us-east-1

# Filter logs by keyword
aws logs tail /ecs/dmstcont --filter-pattern "ERROR" --follow

# View logs for specific time range
aws logs tail /ecs/dmstcont --since 1h
```

### CloudWatch Metrics

```bash
# View CPU utilization
aws cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name CPUUtilization \
  --dimensions Name=ServiceName,Value=dmstcont-service Name=ClusterName,Value=dmstcont-cluster \
  --start-time 2023-01-01T00:00:00Z \
  --end-time 2023-01-01T23:59:59Z \
  --period 3600 \
  --statistics Average
```

### Application Insights (Optional)

For .NET applications, configure Application Insights:

```bash
# Install NuGet package
dotnet add package Microsoft.ApplicationInsights.AspNetCore

# Add to Startup.cs
services.AddApplicationInsightsTelemetry();

# Set instrumentation key as environment variable
"environment": [
  {"name": "APPLICATIONINSIGHTS_CONNECTION_STRING", "value": "InstrumentationKey=..."}
]
```

---

## Troubleshooting

### Common Issues

#### 1. Task Fails to Start

```bash
# Check task stopped reason
aws ecs describe-tasks \
  --cluster dmstcont-cluster \
  --tasks <task-arn> \
  --query 'tasks[0].stoppedReason' \
  --output text

# Check container logs
aws logs get-log-events \
  --log-group-name /ecs/dmstcont \
  --log-stream-name ecs/dmstcont/<task-id>
```

**Common Causes**:
- Invalid CPU/memory combination
- Image pull failure (check ECR permissions)
- Application startup failure (check logs)
- Network configuration issues

#### 2. Cannot Pull Image from ECR

```bash
# Verify execution role has ECR permissions
aws iam get-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-name ECS-ECRAccessPolicy

# Verify image exists
aws ecr describe-images \
  --repository-name dmstcont \
  --region us-east-1
```

#### 3. Service Not Reaching Steady State

```bash
# Check service events
aws ecs describe-services \
  --cluster dmstcont-cluster \
  --services dmstcont-service \
  --query 'services[0].events[0:10]'

# Check health check configuration
# Ensure health endpoint (/health) is responding
```

#### 4. Network Connectivity Issues

```bash
# Verify security group allows inbound traffic
aws ec2 describe-security-groups --group-ids sg-xxxxx

# Verify subnets have internet connectivity
# Check route tables and NAT gateway/Internet gateway

# Test connectivity from within task
aws ecs execute-command \
  --cluster dmstcont-cluster \
  --task <task-id> \
  --container dmstcont \
  --interactive \
  --command "/bin/bash"
```

#### 5. Application-Specific Errors

```bash
# Check application logs
aws logs tail /ecs/dmstcont --follow

# Common .NET issues:
# - Missing configuration (appsettings.json)
# - Database connection failures
# - Port binding issues
# - Missing dependencies
```

### Debugging Commands

```bash
# Enable ECS Exec for interactive debugging
aws ecs update-service \
  --cluster dmstcont-cluster \
  --service dmstcont-service \
  --enable-execute-command

# Connect to running container
aws ecs execute-command \
  --cluster dmstcont-cluster \
  --task <task-arn> \
  --container dmstcont \
  --interactive \
  --command "/bin/bash"
```

---

## Scaling and Management

### Manual Scaling

```bash
# Update desired count
aws ecs update-service \
  --cluster dmstcont-cluster \
  --service dmstcont-service \
  --desired-count 5
```

### Auto Scaling

```bash
# Register scalable target
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/dmstcont-cluster/dmstcont-service \
  --min-capacity 2 \
  --max-capacity 10

# Create scaling policy (target tracking)
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/dmstcont-cluster/dmstcont-service \
  --policy-name cpu-target-tracking \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration file://scaling-policy.json
```

scaling-policy.json:
```json
{
  "TargetValue": 70.0,
  "PredefinedMetricSpecification": {
    "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
  },
  "ScaleOutCooldown": 60,
  "ScaleInCooldown": 60
}
```

### Blue/Green Deployments

```bash
# Update task definition with new image
aws ecs register-task-definition --cli-input-json file://ecs/task-definition.json

# Update service with new task definition
aws ecs update-service \
  --cluster dmstcont-cluster \
  --service dmstcont-service \
  --task-definition dmstcont-task:2 \
  --force-new-deployment
```

---

## Security Considerations

### 1. Container Security

- Use non-root user in Dockerfile (already configured)
- Scan images for vulnerabilities:
  ```bash
  aws ecr start-image-scan --repository-name dmstcont --image-id imageTag=latest
  aws ecr describe-image-scan-findings --repository-name dmstcont --image-id imageTag=latest
  ```

### 2. Network Security

- Use private subnets for tasks with NAT gateway
- Restrict security group rules to minimum required
- Use VPC endpoints for AWS services (ECR, CloudWatch, Secrets Manager)

### 3. Secrets Management

- Never hardcode secrets in code or environment variables
- Use AWS Secrets Manager or Systems Manager Parameter Store
- Grant task role minimal permissions

### 4. IAM Best Practices

- Use separate execution and task roles
- Apply principle of least privilege
- Regularly audit IAM policies

---

## .NET-Specific Considerations

### Runtime Configuration

- **Kestrel Configuration**: Ensure ASPNETCORE_URLS is set correctly
- **Culture Settings**: Set culture in environment variables if needed
- **Timezone**: Set TZ environment variable for consistent time handling

### Performance Tuning

```json
"environment": [
  {"name": "DOTNET_ThreadPool_MinThreads", "value": "10"},
  {"name": "DOTNET_ThreadPool_MaxThreads", "value": "100"},
  {"name": "DOTNET_GCServer", "value": "1"}
]
```

### Memory Management

- Monitor GC performance in CloudWatch
- Adjust task memory based on application needs
- Consider ReadyToRun images for improved startup time

### Health Checks

- Implement ASP.NET Core health checks:
  ```csharp
  services.AddHealthChecks()
      .AddDbContextCheck<ApplicationDbContext>();
  
  app.UseHealthChecks("/health");
  ```

### Logging

- Use structured logging with Serilog:
  ```bash
  dotnet add package Serilog.AspNetCore
  dotnet add package Serilog.Sinks.Console
  ```

---

## Additional Resources

- [AWS ECS Documentation](https://docs.aws.amazon.com/ecs/)
- [AWS Fargate Documentation](https://docs.aws.amazon.com/fargate/)
- [ASP.NET Core Documentation](https://docs.microsoft.com/aspnet/core/)
- [Docker Best Practices](https://docs.docker.com/develop/dev-best-practices/)

---

## Support and Feedback

For issues or questions:
- Check CloudWatch logs: `/ecs/dmstcont`
- Review ECS service events
- Consult AWS ECS troubleshooting documentation
- Review .NET application logs for application-specific errors

---

**Document Version**: 1.0  
**Last Updated**: 2024  
**Application**: DMSTCont  
**Framework**: .NET 5.0  
**Platform**: AWS ECS Fargate