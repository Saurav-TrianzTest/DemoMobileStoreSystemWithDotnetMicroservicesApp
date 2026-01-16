#!/bin/bash
set -e
set -o pipefail

echo "============================================"
echo "  Microservices Docker Build and Push"
echo "============================================"
echo ""

# Project configuration
PROJECT_NAME="microservices-app"

# Microservices configuration
declare -A SERVICES=(
  ["catalog-api"]="src/catalog/Catalog.API|Catalog.API"
  ["basket-api"]="src/Basket/BasketAPI|BasketAPI"
  ["ordering-api"]="src/Ordering/Ordering|Ordering.API"
  ["api-gateway"]="src/ApiGateway/ApiGateway|ApiGateway"
  ["ui-layer"]="src/UI_Layer|AspnetRunBasics"
)

# Select registry type
echo "Select Docker Registry:"
echo "1. AWS ECR"
echo "2. Docker Hub"
read -p "Enter choice (1 or 2): " REGISTRY_CHOICE

if [ "$REGISTRY_CHOICE" = "1" ]; then
  # AWS ECR Configuration
  read -p "Enter AWS Region (e.g., us-east-1): " AWS_REGION
  read -p "Enter AWS Account ID: " AWS_ACCOUNT_ID
  
  REGISTRY_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  
  echo ""
  echo "Authenticating with AWS ECR..."
  aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY_URL"
  
  if [ $? -ne 0 ]; then
    echo "ERROR: ECR authentication failed"
    exit 1
  fi
  
  echo "ECR authentication successful"
  
elif [ "$REGISTRY_CHOICE" = "2" ]; then
  # Docker Hub Configuration
  read -p "Enter Docker Hub username: " DOCKER_USERNAME
  read -sp "Enter Docker Hub password/token: " DOCKER_PASSWORD
  echo ""
  
  echo "Authenticating with Docker Hub..."
  echo "$DOCKER_PASSWORD" | docker login --username "$DOCKER_USERNAME" --password-stdin
  
  if [ $? -ne 0 ]; then
    echo "ERROR: Docker Hub authentication failed"
    exit 1
  fi
  
  REGISTRY_URL="$DOCKER_USERNAME"
  echo "Docker Hub authentication successful"
  
else
  echo "Invalid choice. Exiting."
  exit 1
fi

echo ""
read -p "Enter image tag (default: latest): " IMAGE_TAG
IMAGE_TAG=${IMAGE_TAG:-latest}

# Sanitize tag
IMAGE_TAG=$(echo "$IMAGE_TAG" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9.-' '-' | sed 's/^-*//;s/-*$//')
if [ -z "$IMAGE_TAG" ]; then
  IMAGE_TAG="latest"
fi

echo ""
echo "Building and pushing microservices..."
echo ""

# Build and push each service
for SERVICE_NAME in "${!SERVICES[@]}"; do
  IFS='|' read -r PROJECT_PATH PROJECT_NAME <<< "${SERVICES[$SERVICE_NAME]}"
  
  # Sanitize service name for image
  IMAGE_NAME=$(echo "$SERVICE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')
  
  if [ "$REGISTRY_CHOICE" = "1" ]; then
    # ECR: Create repository if it doesn't exist
    ECR_REPO="$IMAGE_NAME"
    echo "Checking ECR repository: $ECR_REPO"
    aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$AWS_REGION" >/dev/null 2>&1 || {
      echo "Creating ECR repository: $ECR_REPO"
      aws ecr create-repository --repository-name "$ECR_REPO" --region "$AWS_REGION"
    }
    FULL_IMAGE_NAME="${REGISTRY_URL}/${ECR_REPO}:${IMAGE_TAG}"
  else
    # Docker Hub
    FULL_IMAGE_NAME="${REGISTRY_URL}/${IMAGE_NAME}:${IMAGE_TAG}"
  fi
  
  echo ""
  echo "=== Building $SERVICE_NAME ==="
  echo "Project Path: $PROJECT_PATH"
  echo "Project Name: $PROJECT_NAME"
  echo "Image: $FULL_IMAGE_NAME"
  echo ""
  
  # Build Docker image
  docker build \
    -f Dockerfile \
    --build-arg PROJECT_PATH="$PROJECT_PATH" \
    --build-arg PROJECT_NAME="$PROJECT_NAME" \
    -t "$FULL_IMAGE_NAME" \
    .
  
  if [ $? -ne 0 ]; then
    echo "ERROR: Docker build failed for $SERVICE_NAME"
    exit 1
  fi
  
  echo ""
  echo "Pushing $FULL_IMAGE_NAME..."
  docker push "$FULL_IMAGE_NAME"
  
  if [ $? -ne 0 ]; then
    echo "ERROR: Docker push failed for $SERVICE_NAME"
    exit 1
  fi
  
  echo "✓ Successfully built and pushed $SERVICE_NAME"
done

echo ""
echo "============================================"
echo "  All microservices built and pushed!"
echo "============================================"
echo ""
echo "Images:"
for SERVICE_NAME in "${!SERVICES[@]}"; do
  IMAGE_NAME=$(echo "$SERVICE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')
  if [ "$REGISTRY_CHOICE" = "1" ]; then
    echo "  - ${REGISTRY_URL}/${IMAGE_NAME}:${IMAGE_TAG}"
  else
    echo "  - ${REGISTRY_URL}/${IMAGE_NAME}:${IMAGE_TAG}"
  fi
done
echo ""
echo "Next steps:"
echo "1. Run ./scripts/deploy-image.sh to deploy to AWS ECS"
echo "2. Or use docker-compose up to run locally"
echo ""