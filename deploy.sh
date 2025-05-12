set -e

# Ambil REPO_NAME dari environment variable, default ke "myapp" jika tidak diset
APP_NAME=${REPO_NAME:-"myapp"}

echo "🚀 Working with App: $APP_NAME"

# Load configuration from config.json
if [ -f "config.json" ]; then
    echo "📋 Loading configuration from config.json..."
    
    # Check if jq is available
    if command -v jq &> /dev/null; then
        # Try to get app-specific configuration
        TARGET_PORT=$(jq -r ".apps.\"$APP_NAME\".targetPort // .defaults.targetPort" config.json)
        NODE_PORT=$(jq -r ".apps.\"$APP_NAME\".nodePort // .defaults.nodePort" config.json)
    else
        echo "⚠️ jq command not found. Using default ports."
        TARGET_PORT=3000
        NODE_PORT=30000
        
        # Calculate port based on app name hash if no config
        # This is a fallback strategy if jq isn't available
        APP_HASH=$(echo -n "$APP_NAME" | md5sum | tr -d -c 0-9 | cut -c 1-4)
        TARGET_PORT=$((3000 + APP_HASH % 1000))
        NODE_PORT=$((30000 + APP_HASH % 1000))
    fi
else
    echo "⚠️ config.json not found. Using port calculation based on app name."
    # Calculate port based on app name hash
    APP_HASH=$(echo -n "$APP_NAME" | md5sum | tr -d -c 0-9 | cut -c 1-4)
    TARGET_PORT=$((3000 + APP_HASH % 1000))
    NODE_PORT=$((30000 + APP_HASH % 1000))
fi

echo "🔌 Using ports: TARGET_PORT=$TARGET_PORT, NODE_PORT=$NODE_PORT"

# Check if service exists
if ! microk8s kubectl get service ${APP_NAME}-service &> /dev/null; then
    echo "🔄 Service ${APP_NAME}-service belum ada, melakukan setup awal..."
    
    echo "📦 Deploying initial blue version for ${APP_NAME}..."
    sed -e "s/__APP_NAME__/${APP_NAME}/g" \
        -e "s/__TARGET_PORT__/${TARGET_PORT}/g" \
       manifests/deployment-blue.template.yaml | microk8s kubectl apply -f -
    
    echo "📦 Deploying initial green version for ${APP_NAME}..."
    sed -e "s/__APP_NAME__/${APP_NAME}/g" \
        -e "s/__TARGET_PORT__/${TARGET_PORT}/g" \
       manifests/deployment-green.template.yaml | microk8s kubectl apply -f -
    
    echo "🔌 Deploying service ${APP_NAME}-service..."
    sed -e "s/__APP_NAME__/${APP_NAME}/g" \
        -e "s/__TARGET_PORT__/${TARGET_PORT}/g" \
        -e "s/__NODE_PORT__/${NODE_PORT}/g" \
       manifests/service.template.yaml | microk8s kubectl apply -f -
    
    echo "🎯 Setting initial active version to blue for ${APP_NAME}-service..."
    microk8s kubectl patch service ${APP_NAME}-service -p \
        "{\"spec\": {\"selector\": {\"app\": \"${APP_NAME}\", \"version\": \"blue\"}}}"
    
    echo "✅ Initial setup complete for ${APP_NAME}"
fi

# 💡 Ambil versi aktif dari Service (blue atau green)
ACTIVE_VERSION=$(microk8s kubectl get service ${APP_NAME}-service -o jsonpath="{.spec.selector.version}")
if [ "$ACTIVE_VERSION" = "blue" ]; then
  NEW_VERSION="green"
else
  NEW_VERSION="blue"
fi

OLD_VERSION=$ACTIVE_VERSION

echo "Active version for ${APP_NAME}: $ACTIVE_VERSION"
echo "Deploying new version for ${APP_NAME}: $NEW_VERSION"

# 🔨 Build and push image
echo "Building Docker image for ${APP_NAME} version $NEW_VERSION..."

PROJECT_DIR="/workspace/${APP_NAME}"


docker build -t ${APP_NAME}:${NEW_VERSION} "$PROJECT_DIR"

echo "Importing image ${APP_NAME}:${NEW_VERSION} into MicroK8s registry..."
docker save ${APP_NAME}:${NEW_VERSION} | microk8s ctr image import -

# 🚀 Apply deployment
echo "Applying deployment for ${APP_NAME}-${NEW_VERSION}..."
sed -e "s/__APP_NAME__/${APP_NAME}/g" \
    -e "s/__TARGET_PORT__/${TARGET_PORT}/g" \
    manifests/deployment-${NEW_VERSION}.template.yaml | microk8s kubectl apply -f -

# ⏱️ Tunggu sampai ready
echo "Waiting for deployment ${APP_NAME}-${NEW_VERSION} to be ready..."
microk8s kubectl rollout status deployment/${APP_NAME}-${NEW_VERSION}

# 🔄 Switch Service selector
echo "Switching service ${APP_NAME}-service to version ${NEW_VERSION}..."
microk8s kubectl patch service ${APP_NAME}-service -p \
  "{\"spec\": {\"selector\": {\"app\": \"${APP_NAME}\", \"version\": \"${NEW_VERSION}\"}}}"

# 🧹 Optional: Bersihkan deployment lama
echo "Cleaning up old deployment: ${APP_NAME}-${OLD_VERSION}..."
microk8s kubectl delete deployment ${APP_NAME}-${OLD_VERSION} --ignore-not-found

echo "✅ Deployment complete for ${APP_NAME}. Now serving version ${NEW_VERSION}."