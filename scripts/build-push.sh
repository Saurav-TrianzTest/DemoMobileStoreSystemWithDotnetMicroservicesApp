#!/bin/bash
set -e

# Script to build and push Docker image to container registry
# Supports AWS ECR and Docker Hub

echo "======================================"
echo "Docker Build and Push Script"
echo "======================================"
echo ""

# Project configuration
PROJECT_NAME="DMSTCont"
DOCKERFILE_PATH="Dockerfile"

# Sanitize image name: lowercase, replace non-alphanumeric with hyphens, trim hyphens
IMAGE_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')

echo "Project: $PROJECT_NAME"
echo "Sanitized Image Name: $IMAGE_NAME"
echo ""

# Select registry type
echo "Select container registry:"
echo "1. AWS ECR (Elastic Container Registry)"
echo "2. Docker Hub"
read -p "Enter choice (1 or 2): " REGISTRY_CHOICE
echo ""

if [ "$REGISTRY_CHOICE" = "1" ]; then
    # AWS ECR Configuration
    echo "AWS ECR Configuration"
    echo "---------------------"
    read -p "Enter AWS Region (e.g., us-east-1): " AWS_REGION
    read -p "Enter AWS Account ID: " AWS_ACCOUNT_ID
    read -p "Enter ECR Repository Name (e.g., dmstcont): " ECR_REPO
    
    REGISTRY_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
    
    echo ""
    echo "Authenticating with AWS ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY_URL"
    
    if [ $? -ne 0 ]; then
        echo "Error: ECR authentication failed"
        exit 1
    fi
    
    echo "Authentication successful"
    echo ""
    
    # Check if repository exists, create if not
    echo "Checking ECR repository..."
    aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$AWS_REGION" >/dev/null 2>&1 || {
        echo "Repository does not exist. Creating ECR repository..."
        aws ecr create-repository --repository-name "$ECR_REPO" --region "$AWS_REGION"
        echo "Repository created successfully"
    }
    echo ""
    
    # Prompt for image tag
    read -p "Enter image tag (default: latest): " IMAGE_TAG
    IMAGE_TAG=$(echo "${IMAGE_TAG:-latest}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9.-' '-' | sed 's/^-*//;s/-*$//')
    
    FULL_IMAGE_NAME="${REGISTRY_URL}/${ECR_REPO}:${IMAGE_TAG}"
    
elif [ "$REGISTRY_CHOICE" = "2" ]; then
    # Docker Hub Configuration
    echo "Docker Hub Configuration"
    echo "------------------------"
    read -p "Enter Docker Hub username: " DOCKER_USERNAME
    read -sp "Enter Docker Hub password or token: " DOCKER_PASSWORD
    echo ""
    
    echo ""
    echo "Authenticating with Docker Hub..."
    echo "$DOCKER_PASSWORD" | docker login --username "$DOCKER_USERNAME" --password-stdin
    
    if [ $? -ne 0 ]; then
        echo "Error: Docker Hub authentication failed"
        exit 1
    fi
    
    echo "Authentication successful"
    echo ""
    
    # Prompt for image tag
    read -p "Enter image tag (default: latest): " IMAGE_TAG
    IMAGE_TAG=$(echo "${IMAGE_TAG:-latest}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9.-' '-' | sed 's/^-*//;s/-*$//')
    
    FULL_IMAGE_NAME="${DOCKER_USERNAME}/${IMAGE_NAME}:${IMAGE_TAG}"
    
else
    echo "Error: Invalid choice. Please select 1 or 2."
    exit 1
fi

echo "Full Image Name: $FULL_IMAGE_NAME"
echo ""

# Build Docker image
echo "======================================"
echo "Building Docker Image"
echo "======================================"
echo "Building: $FULL_IMAGE_NAME"
echo ""

docker build -f "$DOCKERFILE_PATH" -t "$FULL_IMAGE_NAME" .

if [ $? -ne 0 ]; then
    echo "Error: Docker build failed"
    exit 1
fi

echo ""
echo "Build completed successfully"
echo ""

# Push Docker image
echo "======================================"
echo "Pushing Docker Image"
echo "======================================"
echo "Pushing: $FULL_IMAGE_NAME"
echo ""

docker push "$FULL_IMAGE_NAME"

if [ $? -ne 0 ]; then
    echo "Error: Docker push failed"
    exit 1
fi

echo ""
echo "======================================"
echo "Build and Push Completed Successfully"
echo "======================================"
echo ""
echo "Image: $FULL_IMAGE_NAME"
echo ""
echo "Next steps:"
echo "1. Use this image URI in your ECS task definition"
echo "2. Run the deploy-image.sh script to deploy to ECS"
echo ""