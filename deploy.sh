set -e

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

# Git pull to get latest code
echo "📥 Pulling latest code from repository for ${APP_NAME}..."

# Git pull to get latest code
echo "📥 Pulling latest code from repository for ${APP_NAME}..."
SCRIPT_PATH=$(dirname "$0")
PROJECT_DIR="${SCRIPT_PATH}/workspace/${APP_NAME}"
cd "$PROJECT_DIR"
git pull
cd -


# 🔨 Build and push image
echo "Building Docker image for ${APP_NAME} version $NEW_VERSION..."

docker build -t ${APP_NAME}:${NEW_VERSION} "$PROJECT_DIR"

echo "Importing image ${APP_NAME}:${NEW_VERSION} into MicroK8s registry..."
docker save ${APP_NAME}:${NEW_VERSION} | sudo microk8s ctr image import -

# 🚀 Apply deployment
echo "Applying deployment for ${APP_NAME}-${NEW_VERSION}..."
sed -e "s/__APP_NAME__/${APP_NAME}/g" \
    -e "s/__TARGET_PORT__/${TARGET_PORT}/g" \
    -e "s/__DOCKER_PORT__/${DOCKER_PORT}/g" \
    "${SCRIPT_PATH}/manifests/deployment-${NEW_VERSION}.template.yaml" | $KUBECTL_CMD apply -f -

# ⏱️ Tunggu sampai ready
echo "Waiting for deployment ${APP_NAME}-${NEW_VERSION} to be ready..."
$KUBECTL_CMD rollout status deployment/${APP_NAME}-${NEW_VERSION}

# 🔄 Switch Service selector
echo "Switching service ${APP_NAME}-service to version ${NEW_VERSION}..."
$KUBECTL_CMD patch service ${APP_NAME}-service -p \
  "{\"spec\": {\"selector\": {\"app\": \"${APP_NAME}\", \"version\": \"${NEW_VERSION}\"}}}"

# 🧹 Optional: Bersihkan deployment lama
echo "Cleaning up old deployment: ${APP_NAME}-${OLD_VERSION}..."
$KUBECTL_CMD delete deployment ${APP_NAME}-${OLD_VERSION} --ignore-not-found

echo "✅ Deployment complete for ${APP_NAME}. Now serving version ${NEW_VERSION}."
