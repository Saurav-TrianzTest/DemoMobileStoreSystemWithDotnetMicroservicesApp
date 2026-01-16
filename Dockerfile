# Stage 1: Build
FROM mcr.microsoft.com/dotnet/sdk:5.0 AS builder

ARG PROJECT_PATH
ARG PROJECT_NAME

WORKDIR /src

# Copy solution file
COPY *.sln .

# Copy all project files for dependency resolution
COPY src/*/*.csproj ./
RUN for file in $(ls *.csproj); do mkdir -p src/${file%.*}/ && mv $file src/${file%.*}/; done

COPY src/*/*/*.csproj ./
RUN for file in $(ls *.csproj 2>/dev/null || true); do mkdir -p src/$(echo $file | cut -d'.' -f1)/$(echo $file | cut -d'.' -f2)/ && mv $file src/$(echo $file | cut -d'.' -f1)/$(echo $file | cut -d'.' -f2)/ 2>/dev/null || true; done

# Restore dependencies
RUN dotnet restore

# Copy all source code
COPY src/ ./src/

# Build the specific project
WORKDIR /src/${PROJECT_PATH}
RUN dotnet build -c Release -o /app/build

# Publish the application
RUN dotnet publish -c Release -o /app/publish --no-restore

# Stage 2: Runtime
FROM mcr.microsoft.com/dotnet/aspnet:5.0 AS runtime

WORKDIR /app

# Create non-root user for security
RUN groupadd -r appuser && useradd -r -g appuser appuser

# Copy published application
COPY --from=builder /app/publish .

# Set ownership
RUN chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Set environment variables
ENV ASPNETCORE_ENVIRONMENT=Production \
    ASPNETCORE_URLS=http://+:80 \
    DOTNET_RUNNING_IN_CONTAINER=true \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false

# Expose port
EXPOSE 80

# Health check using application endpoint
# Note: No HEALTHCHECK in Dockerfile - let ECS service handle health checks

# Start the application
ENTRYPOINT ["dotnet", "${PROJECT_NAME}.dll"]