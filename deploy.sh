set -e

# Function to ensure ConfigMap exists and is updated
ensure_configmap() {
    local app_name=$1
    local env_file="/var/www/env/${app_name}.env"
    
    if [ -f "$env_file" ]; then
        echo "📝 Ensuring ConfigMap exists and is updated..."
        $KUBECTL_CMD create configmap ${app_name}-env --from-env-file="$env_file" --dry-run=client -o yaml | $KUBECTL_CMD apply -f -
        
        # Verify ConfigMap was created
        if ! $KUBECTL_CMD get configmap ${app_name}-env &> /dev/null; then
            echo "❌ Failed to create ConfigMap ${app_name}-env"
            return 1
        fi
        
        echo "✅ ConfigMap ${app_name}-env created/updated successfully"
        return 0
    else
        echo "⚠️ .env file not found at $env_file"
        return 1
    fi
}

# sudo mount --bind /var/www/lokasi-2 /var/www/aplikasi-1/workspace

# Ambil REPO_NAME dari environment variable, default ke "myapp" jika tidak diset
APP_NAME=${REPO_NAME:-"myapp"}

echo "🚀 Working with App: $APP_NAME"

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
# Load configuration from config.json
if [ -f "$CONFIG_FILE" ]; then
    echo "📋 Loading configuration from config.json..."
    
    # Check if jq is available
    if command -v jq &> /dev/null; then
        # Try to get app-specific configuration
        TARGET_PORT=$(jq -r ".apps.\"$APP_NAME\".dockerPort // .defaults.dockerPort" "$CONFIG_FILE")
        NODE_PORT=$(jq -r ".apps.\"$APP_NAME\".nodePort // .defaults.nodePort" "$CONFIG_FILE")
        DOCKER_PORT=$(jq -r ".apps.\"$APP_NAME\".dockerPort // .defaults.dockerPort" "$CONFIG_FILE")
        DOMAIN=$(jq -r ".apps.\"$APP_NAME\".domain // .defaults.domain" "$CONFIG_FILE")
    else
        echo "⚠️ jq command not found. Using grep/sed fallback to parse config.json."
        TARGET_PORT=$(extract_config_value "$APP_NAME" "dockerPort" "3000" "$CONFIG_FILE")
        NODE_PORT=$(extract_config_value "$APP_NAME" "nodePort" "30000" "$CONFIG_FILE")
        DOCKER_PORT=$(extract_config_value "$APP_NAME" "dockerPort" "3000" "$CONFIG_FILE")
        
        # Check if we failed to parse correctly
        # if [ -z "$TARGET_PORT" ] || [ "$TARGET_PORT" = "3000" ]; then
        #     echo "⚠️ Fallback parsing may have failed, calculating hash-based ports as backup."
        #     APP_HASH=$(echo -n "$APP_NAME" | md5sum | tr -d -c 0-9 | cut -c 1-4)
        #     TARGET_PORT=$((3000 + APP_HASH % 1000))
        #     NODE_PORT=$((30000 + APP_HASH % 1000))
        #     DOCKER_PORT=$TARGET_PORT
        # fi
    fi
else
    echo "⚠️ config.json not found. Using port calculation based on app name."
    # Calculate port based on app name hash
    APP_HASH=$(echo -n "$APP_NAME" | md5sum | tr -d -c 0-9 | cut -c 1-4)
    TARGET_PORT=$((3000 + APP_HASH % 1000))
    NODE_PORT=$((30000 + APP_HASH % 1000))
    DOCKER_PORT=$TARGET_PORT
fi

echo "🔌 Using ports: TARGET_PORT=$TARGET_PORT, NODE_PORT=$NODE_PORT, DOCKER_PORT=$DOCKER_PORT"

# Check if user has MicroK8s permissions, if not try with sudo
KUBECTL_CMD="sudo microk8s kubectl"
TLS_SECRET_NAME="$APP_NAME-tls"

if ! $KUBECTL_CMD get nodes &> /dev/null; then
    echo "⚠️ Insufficient permissions for MicroK8s. Trying with sudo..."
    KUBECTL_CMD="sudo microk8s kubectl"
    
    # Check if sudo works
    if ! $KUBECTL_CMD get nodes &> /dev/null; then
        echo "❌ Error: Cannot access MicroK8s even with sudo."
        echo "Please run the following commands to fix permissions:"
        echo "    sudo usermod -a -G microk8s $USER"
        echo "    sudo chown -R $USER ~/.kube"
        echo "After this, reload the user groups by running 'newgrp microk8s' or reboot."
        exit 1
    fi
fi

# Check if service exists
SERVICE_EXISTS=$($KUBECTL_CMD get service | grep ${APP_NAME}-service | wc -l)
if [ "$SERVICE_EXISTS" -eq 0 ]; then
    # script path
    SCRIPT_PATH=$(dirname "$0")
    echo "🔄 Service ${APP_NAME}-service belum ada, melakukan setup awal..."
    
    # Git pull to get latest code
    echo "📥 Pulling latest code from repository for ${APP_NAME}..."
    SCRIPT_PATH=$(dirname "$0")
    PROJECT_DIR="${SCRIPT_PATH}/workspace/${APP_NAME}"
    cd "$PROJECT_DIR"
    git pull
    cd -
    
    # Build and import the initial images
    echo "🔨 Building Docker images for initial setup..."
    docker build -t ${APP_NAME}:blue "$PROJECT_DIR"
    docker build -t ${APP_NAME}:green "$PROJECT_DIR"
    
    echo "Importing images into MicroK8s registry..."
    docker save ${APP_NAME}:blue | sudo microk8s ctr image import -
    docker save ${APP_NAME}:green | sudo microk8s ctr image import -
    
    # Ensure ConfigMap exists before any deployment
    ensure_configmap "$APP_NAME"
    
    echo "📦 Deploying initial blue version for ${APP_NAME}..."
    sed -e "s/__APP_NAME__/${APP_NAME}/g" \
        -e "s/__TARGET_PORT__/${TARGET_PORT}/g" \
        -e "s/__DOCKER_PORT__/${DOCKER_PORT}/g" \
        "${SCRIPT_PATH}/manifests/deployment-blue.template.yaml" | $KUBECTL_CMD apply -f - 
        
    echo "📦 Deploying initial green version for ${APP_NAME}..."
    sed -e "s/__APP_NAME__/${APP_NAME}/g" \
        -e "s/__TARGET_PORT__/${TARGET_PORT}/g" \
        -e "s/__DOCKER_PORT__/${DOCKER_PORT}/g" \
        "${SCRIPT_PATH}/manifests/deployment-green.template.yaml" | $KUBECTL_CMD apply -f -
        
    echo "🔄 Creating service ${APP_NAME}-service..."
    sed -e "s/__APP_NAME__/${APP_NAME}/g" \
        -e "s/__DOCKER_PORT__/${DOCKER_PORT}/g" \
        -e "s/__NODE_PORT__/${NODE_PORT}/g" \
        "${SCRIPT_PATH}/manifests/service.template.yaml" | $KUBECTL_CMD apply -f -
   
    echo "🎯 Setting initial active version to blue for ${APP_NAME}-service..."
    $KUBECTL_CMD patch service ${APP_NAME}-service -p \
        "{\"spec\": {\"selector\": {\"app\": \"${APP_NAME}\", \"version\": \"blue\"}}}"

    # Create ConfigMap from .env file
    ENV_FILE="/var/www/env/${APP_NAME}.env"
    if [ -f "$ENV_FILE" ]; then
        echo "📝 Creating ConfigMap from .env file..."
        $KUBECTL_CMD create configmap ${APP_NAME}-env --from-env-file="$ENV_FILE" --dry-run=client -o yaml | $KUBECTL_CMD apply -f -
        
        # Update deployments to use the ConfigMap
        echo "🔄 Updating deployments to use ConfigMap..."
        $KUBECTL_CMD  set env deployment/${APP_NAME}-blue --from=configmap/${APP_NAME}-env
        $KUBECTL_CMD  set env deployment/${APP_NAME}-green --from=configmap/${APP_NAME}-env


        $KUBECTL_CMD patch deployment ${APP_NAME}-blue -p \
            "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${APP_NAME}\",\"envFrom\":[{\"configMapRef\":{\"name\":\"${APP_NAME}-env\"}}]}]}}}}"
        $KUBECTL_CMD patch deployment ${APP_NAME}-green -p \
            "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${APP_NAME}\",\"envFrom\":[{\"configMapRef\":{\"name\":\"${APP_NAME}-env\"}}]}]}}}}"
    else
        echo "⚠️ .env file not found at $ENV_FILE"
    fi

    CERT_MANAGER_NS="cert-manager"
    ISSUER_EXISTS=$($KUBECTL_CMD get clusterissuer letsencrypt-prod --ignore-not-found | wc -l)
    if [ "$ISSUER_EXISTS" -eq 0 ]; then
        echo "📜 Creating ClusterIssuer..."
        $KUBECTL_CMD apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: your@email.com
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: public
EOF
    fi

    echo "🌐 Creating Ingress..."
    sed -e "s/__APP_NAME__/$APP_NAME/g" \
        -e "s/__DOMAIN__/$DOMAIN/g" \
        -e "s/__TLS_SECRET__/$TLS_SECRET_NAME/g" \
        "$SCRIPT_DIR/manifests/ingress.template.yaml" | $KUBECTL_CMD apply -f -
    
    echo "✅ Initial setup complete for ${APP_NAME}"
    
    # Since we've already done the git pull and setup, skip the rest of the deployment
    exit 0
fi

# 💡 Ambil versi aktif dari Service (blue atau green)
ACTIVE_VERSION=$($KUBECTL_CMD get service ${APP_NAME}-service -o jsonpath="{.spec.selector.version}")
if [ "$ACTIVE_VERSION" = "blue" ]; then
  NEW_VERSION="green"
else
  NEW_VERSION="blue"
fi

OLD_VERSION=$ACTIVE_VERSION

echo "Active version for ${APP_NAME}: $ACTIVE_VERSION"
echo "Deploying new version for ${APP_NAME}: $NEW_VERSION"

# Send pending status to GitHub
send_github_status "$APP_NAME" "pending" "Deployment is in progress..." ""

# Git pull to get latest code
echo "📥 Pulling latest code from repository for ${APP_NAME}..."

# Git pull to get latest code
echo "📥 Pulling latest code from repository for ${APP_NAME}..."
SCRIPT_PATH=$(dirname "$0")
PROJECT_DIR="${SCRIPT_PATH}/workspace/${APP_NAME}"
cd "$PROJECT_DIR"
git pull
cd -

# Function to verify deployment is using new image
verify_deployment_image() {
    local app_name=$1
    local version=$2
    local expected_image="${app_name}:${version}"
    
    echo "🔍 Verifying deployment is using correct image..."
    
    # Get the current image
    local current_image=$($KUBECTL_CMD get deployment ${app_name}-${version} -o jsonpath="{.spec.template.spec.containers[0].image}")
    
    if [ "$current_image" != "$expected_image" ]; then
        echo "❌ Deployment is not using the correct image"
        echo "Expected: $expected_image"
        echo "Current: $current_image"
        return 1
    fi
    
    # Force pull new image
    echo "🔄 Forcing image pull..."
    $KUBECTL_CMD set image deployment/${app_name}-${version} ${app_name}=${expected_image} --record
    
    # Wait for rollout to complete
    echo "⏱️ Waiting for rollout to complete..."
    $KUBECTL_CMD rollout status deployment/${app_name}-${version} --timeout=300s
    
    # Verify pod is using new image
    local pod_name=$($KUBECTL_CMD get pod -l app=${app_name},version=${version} -o jsonpath="{.items[0].metadata.name}")
    local pod_image=$($KUBECTL_CMD get pod $pod_name -o jsonpath="{.spec.containers[0].image}")
    
    if [ "$pod_image" != "$expected_image" ]; then
        echo "❌ Pod is not using the correct image"
        echo "Expected: $expected_image"
        echo "Current: $pod_image"
        return 1
    fi
    
    echo "✅ Deployment verified using correct image"
    return 0
}

# Pada bagian update deployment
echo "Applying deployment for ${APP_NAME}-${NEW_VERSION}..."

# Ensure ConfigMap exists before deployment
ensure_configmap "$APP_NAME"

# Build and import the new image
echo "Building Docker image for ${APP_NAME} version $NEW_VERSION..."
docker build -t ${APP_NAME}:${NEW_VERSION} "$PROJECT_DIR"

echo "Importing image ${APP_NAME}:${NEW_VERSION} into MicroK8s registry..."
docker save ${APP_NAME}:${NEW_VERSION} | sudo microk8s ctr image import -

# Apply deployment with ConfigMap
echo "🚀 Applying deployment for ${APP_NAME}-${NEW_VERSION}..."
sed -e "s/__APP_NAME__/${APP_NAME}/g" \
    -e "s/__TARGET_PORT__/${TARGET_PORT}/g" \
    -e "s/__DOCKER_PORT__/${DOCKER_PORT}/g" \
    "${SCRIPT_PATH}/manifests/deployment-${NEW_VERSION}.template.yaml" | $KUBECTL_CMD apply -f -

# Verify deployment is using new image
verify_deployment_image "$APP_NAME" "$NEW_VERSION"

# Check if deployment verification failed
if [ $? -ne 0 ]; then
    echo "❌ Deployment verification failed"
    
    # Send failure status to GitHub
    send_github_status "$APP_NAME" "failure" "Deployment verification failed - image not updated" ""
    
    # Send error notification to Telegram
    send_telegram_notification "$APP_NAME" "$NEW_VERSION" "error" "Deployment verification failed - image not updated"
    
    exit 1
fi

# Switch service to new version
echo "🔄 Switching service ${APP_NAME}-service to version ${NEW_VERSION}..."
$KUBECTL_CMD patch service ${APP_NAME}-service -p \
  "{\"spec\": {\"selector\": {\"app\": \"${APP_NAME}\", \"version\": \"${NEW_VERSION}\"}}}"

# Wait for service to be ready
echo "⏱️ Waiting for service to be ready..."
sleep 10

# Verify service is pointing to new version
SERVICE_VERSION=$($KUBECTL_CMD get service ${APP_NAME}-service -o jsonpath="{.spec.selector.version}")
if [ "$SERVICE_VERSION" != "$NEW_VERSION" ]; then
    echo "❌ Service is not pointing to the new version"
    echo "Expected: $NEW_VERSION"
    echo "Current: $SERVICE_VERSION"
    
    # Send failure status to GitHub
    send_github_status "$APP_NAME" "failure" "Service failed to switch to new version" ""
    
    # Send error notification to Telegram
    send_telegram_notification "$APP_NAME" "$NEW_VERSION" "error" "Service failed to switch to new version"
    
    exit 1
fi

# Clean up old deployment
echo "🧹 Cleaning up old deployment: ${APP_NAME}-${OLD_VERSION}..."
$KUBECTL_CMD delete deployment ${APP_NAME}-${OLD_VERSION} --ignore-not-found

echo "✅ Deployment complete for ${APP_NAME}. Now serving version ${NEW_VERSION}."

# Send success status to GitHub
send_github_status "$APP_NAME" "success" "Deployment completed successfully" ""

# Send success notification
send_telegram_notification "$APP_NAME" "$NEW_VERSION" "success" "Deployment completed successfully. Service is now running version $NEW_VERSION."

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
    "context": "ci/cd-deployer"
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

# Pada bagian error handling (update existing error handling)
# Ganti bagian error handling yang ada dengan ini:
handle_deployment_error() {
    local app_name=$1
    local version=$2
    local error_message=$3
    
    echo "❌ Deployment failed: $error_message"
    
    # Send failure status to GitHub
    send_github_status "$app_name" "failure" "Deployment failed: $error_message" ""
    
    # Send error notification to Telegram
    send_telegram_notification "$app_name" "$version" "error" "Deployment failed: $error_message"
    
    exit 1
}
