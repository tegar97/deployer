set -e

# Function to send Telegram notification
send_telegram_notification() {
    local app_name=$1
    local version=$2
    local status=$3
    local message=$4

    # Get Telegram configuration from config.json
    if [ -f "$CONFIG_FILE" ]; then
        if command -v jq &> /dev/null; then
            TELEGRAM_BOT_TOKEN=$(jq -r ".telegram.botToken // empty" "$CONFIG_FILE")
            TELEGRAM_CHAT_ID=$(jq -r ".telegram.chatId // empty" "$CONFIG_FILE")
        else
            # Fallback using grep/sed if jq is not available
            TELEGRAM_BOT_TOKEN=$(grep -A5 "\"telegram\":" "$CONFIG_FILE" | grep "\"botToken\":" | head -1 | sed 's/.*"botToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            TELEGRAM_CHAT_ID=$(grep -A5 "\"telegram\":" "$CONFIG_FILE" | grep "\"chatId\":" | head -1 | sed 's/.*"chatId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        fi
    fi

    # Check if Telegram configuration exists
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo "⚠️ Telegram configuration not found in config.json"
        return 1
    fi

    # Prepare message
    local emoji="✅"
    if [ "$status" = "error" ]; then
        emoji="❌"
    fi

    local full_message="*Deployment Status* $emoji\n\n*App:* \`$app_name\`\n*Version:* \`$version\`\n*Status:* \`$status\`\n\n$message"

    # Send notification
    echo "📱 Sending Telegram notification..."
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"$TELEGRAM_CHAT_ID\",\"text\":\"$full_message\",\"parse_mode\":\"Markdown\"}" \
        "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage"

    if [ $? -eq 0 ]; then
        echo "✅ Telegram notification sent successfully"
        return 0
    else
        echo "❌ Failed to send Telegram notification"
        return 1
    fi
}

# Function to send GitHub commit status
send_github_status() {
    local app_name=$1
    local status=$2
    local description=$3
    local target_url=$4

    # Get GitHub configuration from config.json
    if [ -f "$CONFIG_FILE" ]; then
        if command -v jq &> /dev/null; then
            GITHUB_TOKEN=$(jq -r ".github.token // empty" "$CONFIG_FILE")
            GITHUB_OWNER=$(jq -r ".github.owner // empty" "$CONFIG_FILE")
            GITHUB_REPO=$(jq -r ".apps.\"$app_name\".repo // .github.defaultRepo // empty" "$CONFIG_FILE")
        else
            # Fallback using grep/sed if jq is not available
            GITHUB_TOKEN=$(grep -A10 "\"github\":" "$CONFIG_FILE" | grep "\"token\":" | head -1 | sed 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            GITHUB_OWNER=$(grep -A10 "\"github\":" "$CONFIG_FILE" | grep "\"owner\":" | head -1 | sed 's/.*"owner"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            GITHUB_REPO=$(grep -A20 "\"$app_name\":" "$CONFIG_FILE" | grep "\"repo\":" | head -1 | sed 's/.*"repo"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        fi
    fi

    # Check if GitHub configuration exists
    if [ -z "$GITHUB_TOKEN" ] || [ -z "$GITHUB_OWNER" ] || [ -z "$GITHUB_REPO" ]; then
        echo "⚠️ GitHub configuration not found in config.json (token, owner, or repo missing)"
        return 1
    fi

    # Get current commit SHA
    local project_dir="${SCRIPT_DIR}/workspace/${app_name}"
    if [ -d "$project_dir/.git" ]; then
        cd "$project_dir"
        local commit_sha=$(git rev-parse HEAD)
        cd -
    else
        echo "⚠️ Git repository not found for $app_name"
        return 1
    fi

    # Set default target URL if not provided
    if [ -z "$target_url" ]; then
        target_url="https://github.com/$GITHUB_OWNER/$GITHUB_REPO/commit/$commit_sha"
    fi

    # Prepare JSON payload
    local json_payload=$(cat <<EOF
{
    "state": "$status",
    "target_url": "$target_url",
    "description": "$description",
    "context": "ci/cd-deployer-docker"
}
EOF
)

    # Send status to GitHub
    echo "📡 Sending GitHub commit status..."
    local response=$(curl -s -L \
        -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/statuses/$commit_sha" \
        -d "$json_payload")

    if [ $? -eq 0 ]; then
        echo "✅ GitHub commit status sent successfully"
        echo "   Commit: $commit_sha"
        echo "   Status: $status"
        echo "   Repository: $GITHUB_OWNER/$GITHUB_REPO"
        return 0
    else
        echo "❌ Failed to send GitHub commit status"
        echo "Response: $response"
        return 1
    fi
}

# Function to handle deployment errors
handle_deployment_error() {
    local app_name=$1
    local version=$2
    local error_message=$3

    echo "❌ Deployment failed: $error_message"

    # Send failure status to GitHub
    send_github_status "$app_name" "failure" "Docker deployment failed: $error_message" ""

    # Send error notification to Telegram
    send_telegram_notification "$app_name" "$version" "error" "Docker deployment failed: $error_message"

    exit 1
}

# Function to stop existing container
stop_existing_container() {
    local app_name=$1
    local container_name="${app_name}-container"

    echo "🛑 Stopping existing container if running..."
    if docker ps -q -f name=$container_name | grep -q .; then
        echo "📦 Found running container: $container_name"
        docker stop $container_name
        docker rm $container_name
        echo "✅ Container $container_name stopped and removed"
    else
        echo "ℹ️ No running container found for $container_name"
    fi
}

# Function to prepare environment variables
prepare_env_vars() {
    local app_name=$1
    local env_file="/var/www/env/${app_name}.env"
    
    ENV_ARGS=""
    
    if [ -f "$env_file" ]; then
        echo "📝 Loading environment variables from $env_file"
        ENV_ARGS="--env-file $env_file"
        echo "✅ Environment file loaded"
    else
        echo "⚠️ .env file not found at $env_file, continuing without environment variables"
    fi
}

# Function to extract config values without jq
extract_config_value() {
    local app_name="$1"
    local key="$2"
    local default_value="$3"
    local config_file="$4"

    # Try to extract app-specific value
    local app_value=$(grep -A20 "\"$app_name\":" "$config_file" | grep "\"$key\":" | head -1 | sed 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/')

    # If app-specific value not found, try to get default value
    if [ -z "$app_value" ]; then
        local default_value_from_file=$(grep -A10 "\"defaults\":" "$config_file" | grep "\"$key\":" | head -1 | sed 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/')

        # If default value from file not found, use provided default value
        if [ -z "$default_value_from_file" ]; then
            echo "$default_value"
        else
            echo "$default_value_from_file"
        fi
    else
        echo "$app_value"
    fi
}

# Ambil REPO_NAME dari environment variable, default ke "myapp" jika tidak diset
APP_NAME=${REPO_NAME:-"myapp"}

echo "🚀 Working with App: $APP_NAME (Direct Docker Deployment)"

# Check if jq is installed and install it if not found
if ! command -v jq &> /dev/null; then
    echo "⚙️ jq not found, attempting to install it..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y jq
    elif command -v yum &> /dev/null; then
        sudo yum install -y jq
    elif command -v apk &> /dev/null; then
        sudo apk add --no-cache jq
    else
        echo "⚠️ Could not install jq automatically. Using fallback method for configuration."
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# Load configuration from config.json
if [ -f "$CONFIG_FILE" ]; then
    echo "📋 Loading configuration from config.json..."

    # Check if jq is available
    if command -v jq &> /dev/null; then
        # Try to get app-specific configuration
        DOCKER_PORT=$(jq -r ".apps.\"$APP_NAME\".dockerPort // .defaults.dockerPort" "$CONFIG_FILE")
        HOST_PORT=$(jq -r ".apps.\"$APP_NAME\".hostPort // .apps.\"$APP_NAME\".servicePort // .defaults.servicePort // .defaults.hostPort" "$CONFIG_FILE")
        DOMAIN=$(jq -r ".apps.\"$APP_NAME\".domain // .defaults.domain" "$CONFIG_FILE")
    else
        echo "⚠️ jq command not found. Using grep/sed fallback to parse config.json."
        DOCKER_PORT=$(extract_config_value "$APP_NAME" "dockerPort" "3000" "$CONFIG_FILE")
        HOST_PORT=$(extract_config_value "$APP_NAME" "hostPort" "80" "$CONFIG_FILE")
        if [ -z "$HOST_PORT" ] || [ "$HOST_PORT" = "80" ]; then
            HOST_PORT=$(extract_config_value "$APP_NAME" "servicePort" "80" "$CONFIG_FILE")
        fi
    fi
else
    echo "⚠️ config.json not found. Using port calculation based on app name."
    # Calculate port based on app name hash
    APP_HASH=$(echo -n "$APP_NAME" | md5sum | tr -d -c 0-9 | cut -c 1-4)
    DOCKER_PORT=$((3000 + APP_HASH % 1000))
    HOST_PORT=$((8000 + APP_HASH % 1000))
fi

echo "🔌 Using ports: DOCKER_PORT=$DOCKER_PORT, HOST_PORT=$HOST_PORT"

# Check if Docker is running
if ! docker info &> /dev/null; then
    echo "❌ Docker is not running or accessible"
    handle_deployment_error "$APP_NAME" "latest" "Docker is not running or accessible"
fi

# Git pull to get latest code BEFORE sending status
echo "📥 Pulling latest code from repository for ${APP_NAME}..."
SCRIPT_PATH=$(dirname "$0")
PROJECT_DIR="${SCRIPT_PATH}/workspace/${APP_NAME}"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "❌ Project directory not found: $PROJECT_DIR"
    handle_deployment_error "$APP_NAME" "latest" "Project directory not found: $PROJECT_DIR"
fi

cd "$PROJECT_DIR"
git pull
if [ $? -ne 0 ]; then
    echo "❌ Git pull failed"
    handle_deployment_error "$APP_NAME" "latest" "Git pull failed"
fi
cd -

# Send pending status to GitHub (after git pull to get correct commit SHA)
send_github_status "$APP_NAME" "pending" "Docker deployment is in progress..." ""

# Prepare environment variables
prepare_env_vars "$APP_NAME"

# Stop existing container
stop_existing_container "$APP_NAME"

# Build Docker image
echo "🔨 Building Docker image for ${APP_NAME}..."
docker build -t ${APP_NAME}:latest "$PROJECT_DIR"

if [ $? -ne 0 ]; then
    echo "❌ Docker build failed"
    handle_deployment_error "$APP_NAME" "latest" "Docker build failed"
fi

# Run new container
echo "🚀 Running new Docker container for ${APP_NAME}..."
CONTAINER_NAME="${APP_NAME}-container"

# Build docker run command
DOCKER_RUN_CMD="docker run -d --name $CONTAINER_NAME --restart unless-stopped -p $HOST_PORT:$DOCKER_PORT"

# Add environment variables if available
if [ -n "$ENV_ARGS" ]; then
    DOCKER_RUN_CMD="$DOCKER_RUN_CMD $ENV_ARGS"
fi

# Add image name
DOCKER_RUN_CMD="$DOCKER_RUN_CMD ${APP_NAME}:latest"

echo "📝 Running command: $DOCKER_RUN_CMD"

# Execute docker run
eval $DOCKER_RUN_CMD

if [ $? -ne 0 ]; then
    echo "❌ Failed to start Docker container"
    handle_deployment_error "$APP_NAME" "latest" "Failed to start Docker container"
fi

# Wait a moment for container to start
echo "⏱️ Waiting for container to start..."
sleep 5

# Check if container is running
if ! docker ps -q -f name=$CONTAINER_NAME | grep -q .; then
    echo "❌ Container failed to start or exited"
    echo "📋 Container logs:"
    docker logs $CONTAINER_NAME
    handle_deployment_error "$APP_NAME" "latest" "Container failed to start or exited"
fi

# Check container health
echo "🔍 Checking container health..."
CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' $CONTAINER_NAME)

if [ "$CONTAINER_STATUS" != "running" ]; then
    echo "❌ Container is not running. Status: $CONTAINER_STATUS"
    echo "📋 Container logs:"
    docker logs $CONTAINER_NAME
    handle_deployment_error "$APP_NAME" "latest" "Container is not running. Status: $CONTAINER_STATUS"
fi

# Test if application is responding
echo "🌐 Testing application response..."
sleep 2

# Try to test the application endpoint
if command -v curl &> /dev/null; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$HOST_PORT/ || echo "000")
    if [ "$HTTP_CODE" != "000" ]; then
        echo "✅ Application is responding (HTTP $HTTP_CODE)"
    else
        echo "⚠️ Application might not be ready yet, but container is running"
    fi
else
    echo "⚠️ curl not available, skipping HTTP test"
fi

# Clean up old images (keep last 3)
echo "🧹 Cleaning up old Docker images..."
docker images ${APP_NAME} --format "table {{.Repository}}:{{.Tag}}\t{{.CreatedAt}}" | tail -n +2 | head -n -3 | awk '{print $1}' | xargs -r docker rmi

echo "✅ Direct Docker deployment complete for ${APP_NAME}"
echo "🔗 Application accessible at:"
echo "   - http://localhost:$HOST_PORT"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "null" ]; then
    echo "   - http://$DOMAIN:$HOST_PORT (if domain is configured)"
fi

# Send success status to GitHub
send_github_status "$APP_NAME" "success" "Docker deployment completed successfully" ""

# Send success notification
send_telegram_notification "$APP_NAME" "latest" "success" "Docker deployment completed successfully. Service is running on port $HOST_PORT." 