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
    "context": "ci/cd-deployer-direct"
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
    send_github_status "$app_name" "failure" "Direct deployment failed: $error_message" ""

    # Send error notification to Telegram
    send_telegram_notification "$app_name" "$version" "error" "Direct deployment failed: $error_message"

    exit 1
}

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

# Function to check if HAProxy is needed
check_haproxy_needed() {
    local app_name=$1
    local service_port=$2
    local node_port=$3

    # HAProxy is needed if servicePort is different from nodePort
    # This allows users to access apps on custom ports while Kubernetes uses standard NodePorts
    if [ "$service_port" != "$node_port" ] && [ "$service_port" != "null" ] && [ -n "$service_port" ]; then
        echo "🔀 HAProxy redirection needed: $service_port -> $node_port"
        return 0
    else
        echo "ℹ️ No HAProxy redirection needed for $app_name"
        return 1
    fi
}

# Function to install HAProxy if not present
ensure_haproxy_installed() {
    if ! command -v haproxy &> /dev/null; then
        echo "🔧 HAProxy not found, installing..."

        # Use the haproxy-setup.sh script to install
        if [ -f "$SCRIPT_DIR/haproxy-setup.sh" ]; then
            chmod +x "$SCRIPT_DIR/haproxy-setup.sh"
            "$SCRIPT_DIR/haproxy-setup.sh" install
        else
            echo "❌ haproxy-setup.sh not found. Installing HAProxy manually..."
            if command -v apt-get &> /dev/null; then
                sudo apt-get update && sudo apt-get install -y haproxy
            elif command -v yum &> /dev/null; then
                sudo yum install -y haproxy
            elif command -v dnf &> /dev/null; then
                sudo dnf install -y haproxy
            else
                echo "❌ Cannot install HAProxy automatically"
                return 1
            fi
            sudo systemctl enable haproxy
        fi

        echo "✅ HAProxy installation completed"
    else
        echo "✅ HAProxy is already installed"
    fi

    return 0
}

# Function to update HAProxy configuration
update_haproxy_config() {
    echo "🔄 Updating HAProxy configuration..."

    # Use the haproxy-setup.sh script to generate and apply configuration
    if [ -f "$SCRIPT_DIR/haproxy-setup.sh" ]; then
        chmod +x "$SCRIPT_DIR/haproxy-setup.sh"
        "$SCRIPT_DIR/haproxy-setup.sh" config

        # Restart HAProxy to apply new configuration
        if "$SCRIPT_DIR/haproxy-setup.sh" restart; then
            echo "✅ HAProxy configuration updated and service restarted"
            return 0
        else
            echo "❌ Failed to restart HAProxy"
            return 1
        fi
    else
        echo "❌ haproxy-setup.sh not found. Cannot update HAProxy configuration."
        return 1
    fi
}

# Ambil REPO_NAME dari environment variable, default ke "myapp" jika tidak diset
APP_NAME=${REPO_NAME:-"myapp"}

echo "🚀 Working with App: $APP_NAME (Direct Deployment)"

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
        SERVICE_PORT=$(jq -r ".apps.\"$APP_NAME\".servicePort // .defaults.servicePort" "$CONFIG_FILE")
        DOMAIN=$(jq -r ".apps.\"$APP_NAME\".domain // .defaults.domain" "$CONFIG_FILE")
    else
        echo "⚠️ jq command not found. Using grep/sed fallback to parse config.json."
        TARGET_PORT=$(extract_config_value "$APP_NAME" "dockerPort" "3000" "$CONFIG_FILE")
        NODE_PORT=$(extract_config_value "$APP_NAME" "nodePort" "30000" "$CONFIG_FILE")
        DOCKER_PORT=$(extract_config_value "$APP_NAME" "dockerPort" "3000" "$CONFIG_FILE")
        SERVICE_PORT=$(extract_config_value "$APP_NAME" "servicePort" "80" "$CONFIG_FILE")
    fi
else
    echo "⚠️ config.json not found. Using port calculation based on app name."
    # Calculate port based on app name hash
    APP_HASH=$(echo -n "$APP_NAME" | md5sum | tr -d -c 0-9 | cut -c 1-4)
    TARGET_PORT=$((3000 + APP_HASH % 1000))
    NODE_PORT=$((30000 + APP_HASH % 1000))
    DOCKER_PORT=$TARGET_PORT
    SERVICE_PORT=80
fi

echo "🔌 Using ports: TARGET_PORT=$TARGET_PORT, NODE_PORT=$NODE_PORT, DOCKER_PORT=$DOCKER_PORT, SERVICE_PORT=$SERVICE_PORT"

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

# Git pull to get latest code BEFORE sending status
echo "📥 Pulling latest code from repository for ${APP_NAME}..."
SCRIPT_PATH=$(dirname "$0")
PROJECT_DIR="${SCRIPT_PATH}/workspace/${APP_NAME}"
cd "$PROJECT_DIR"
git pull
cd -

# Send pending status to GitHub (after git pull to get correct commit SHA)
send_github_status "$APP_NAME" "pending" "Direct deployment is in progress..." ""

# Check if service exists for initial setup
SERVICE_EXISTS=$($KUBECTL_CMD get service | grep ${APP_NAME}-service | wc -l)
if [ "$SERVICE_EXISTS" -eq 0 ]; then
    echo "🔄 Service ${APP_NAME}-service belum ada, melakukan setup awal..."

    # Ensure ConfigMap exists before any deployment
    ensure_configmap "$APP_NAME"

    echo "🌐 Creating service ${APP_NAME}-service..."
    sed -e "s/__APP_NAME__/${APP_NAME}/g" \
        -e "s/__DOCKER_PORT__/${DOCKER_PORT}/g" \
        -e "s/__NODE_PORT__/${NODE_PORT}/g" \
        -e "s/__SERVICE_PORT__/${SERVICE_PORT}/g" \
        "${SCRIPT_PATH}/manifests/service.template.yaml" | $KUBECTL_CMD apply -f -

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
        -e "s/__SERVICE_PORT__/$SERVICE_PORT/g" \
        "$SCRIPT_DIR/manifests/ingress.template.yaml" | $KUBECTL_CMD apply -f -

    # Check if HAProxy is needed for port redirection
    if check_haproxy_needed "$APP_NAME" "$SERVICE_PORT" "$NODE_PORT"; then
        echo "🔧 Setting up HAProxy for port redirection..."

        # Ensure HAProxy is installed
        if ensure_haproxy_installed; then
            # Update HAProxy configuration
            update_haproxy_config

            echo "✅ HAProxy setup completed"
            echo "🔗 Port redirection active:"
            echo "   - User can access app on port: $SERVICE_PORT"
            echo "   - HAProxy redirects to Kubernetes NodePort: $NODE_PORT"
        else
            echo "⚠️ HAProxy setup failed, but deployment will continue"
        fi
    fi
fi

# Build and import the new image
echo "🔨 Building Docker image for ${APP_NAME}..."
docker build -t ${APP_NAME}:latest "$PROJECT_DIR"

echo "📦 Importing image ${APP_NAME}:latest into MicroK8s registry..."
docker save ${APP_NAME}:latest | sudo microk8s ctr image import -

# Ensure ConfigMap exists before deployment
ensure_configmap "$APP_NAME"

# Deploy directly without blue-green switching
echo "🚀 Deploying ${APP_NAME} directly (no blue-green)..."

# Check if deployment exists
DEPLOYMENT_EXISTS=$($KUBECTL_CMD get deployment ${APP_NAME} --ignore-not-found | wc -l)

if [ "$DEPLOYMENT_EXISTS" -eq 0 ]; then
    echo "📦 Creating new deployment ${APP_NAME}..."
    # Create deployment using blue template but without version suffix
    sed -e "s/__APP_NAME__/${APP_NAME}/g" \
        -e "s/__TARGET_PORT__/${TARGET_PORT}/g" \
        -e "s/__DOCKER_PORT__/${DOCKER_PORT}/g" \
        -e "s/version: blue/version: latest/g" \
        -e "s/${APP_NAME}-blue/${APP_NAME}/g" \
        "${SCRIPT_PATH}/manifests/deployment-blue.template.yaml" | $KUBECTL_CMD apply -f -
else
    echo "🔄 Updating existing deployment ${APP_NAME}..."
    # Update existing deployment
    $KUBECTL_CMD set image deployment/${APP_NAME} ${APP_NAME}=${APP_NAME}:latest --record
fi

# Wait for deployment to be ready
echo "⏱️ Waiting for deployment to be ready..."
$KUBECTL_CMD rollout status deployment/${APP_NAME} --timeout=300s

if [ $? -ne 0 ]; then
    handle_deployment_error "$APP_NAME" "latest" "Deployment rollout failed"
fi

# Update service selector to point to the deployment (without version)
echo "🔄 Updating service ${APP_NAME}-service to point to deployment..."
$KUBECTL_CMD patch service ${APP_NAME}-service -p \
  "{\"spec\": {\"selector\": {\"app\": \"${APP_NAME}\", \"version\": \"latest\"}}}"

# Wait for service to be ready
echo "⏱️ Waiting for service to be ready..."
sleep 10

# Verify service is working
SERVICE_VERSION=$($KUBECTL_CMD get service ${APP_NAME}-service -o jsonpath="{.spec.selector.version}")
if [ "$SERVICE_VERSION" != "latest" ]; then
    handle_deployment_error "$APP_NAME" "latest" "Service is not pointing to the new deployment"
fi

# Update HAProxy configuration if needed
if check_haproxy_needed "$APP_NAME" "$SERVICE_PORT" "$NODE_PORT"; then
    echo "🔄 Updating HAProxy configuration for port redirection..."

    # Ensure HAProxy is installed
    if ensure_haproxy_installed; then
        # Update HAProxy configuration
        if update_haproxy_config; then
            echo "✅ HAProxy configuration updated successfully"
            echo "🔗 Port redirection active:"
            echo "   - User can access app on port: $SERVICE_PORT"
            echo "   - HAProxy redirects to Kubernetes NodePort: $NODE_PORT"
        else
            echo "⚠️ HAProxy configuration update failed, but deployment completed successfully"
        fi
    else
        echo "⚠️ HAProxy installation failed, but deployment completed successfully"
    fi
fi

echo "✅ Direct deployment complete for ${APP_NAME}. Now serving latest version."

# Send success status to GitHub
send_github_status "$APP_NAME" "success" "Direct deployment completed successfully" ""

# Send success notification
send_telegram_notification "$APP_NAME" "latest" "success" "Direct deployment completed successfully. Service is now running latest version." 