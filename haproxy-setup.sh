#!/bin/bash

# HAProxy Setup and Configuration Script
# This script installs HAProxy and configures it to redirect traffic
# from default Kubernetes NodePort (30080) to custom service ports

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
HAPROXY_CONFIG="/etc/haproxy/haproxy.cfg"
HAPROXY_BACKUP="/etc/haproxy/haproxy.cfg.backup"

# Function to install HAProxy
install_haproxy() {
    echo "🔧 Installing HAProxy..."
    
    if command -v haproxy &> /dev/null; then
        echo "✅ HAProxy is already installed"
        haproxy -v
        return 0
    fi
    
    # Detect OS and install HAProxy
    if command -v apt-get &> /dev/null; then
        echo "📦 Installing HAProxy on Ubuntu/Debian..."
        sudo apt-get update
        sudo apt-get install -y haproxy
    elif command -v yum &> /dev/null; then
        echo "📦 Installing HAProxy on CentOS/RHEL..."
        sudo yum install -y haproxy
    elif command -v dnf &> /dev/null; then
        echo "📦 Installing HAProxy on Fedora..."
        sudo dnf install -y haproxy
    else
        echo "❌ Unsupported operating system. Please install HAProxy manually."
        exit 1
    fi
    
    # Enable HAProxy service
    sudo systemctl enable haproxy
    echo "✅ HAProxy installed successfully"
}

# Function to backup current HAProxy config
backup_haproxy_config() {
    if [ -f "$HAPROXY_CONFIG" ]; then
        echo "💾 Backing up current HAProxy configuration..."
        sudo cp "$HAPROXY_CONFIG" "$HAPROXY_BACKUP"
        echo "✅ Backup created at $HAPROXY_BACKUP"
    fi
}

# Function to generate HAProxy configuration
generate_haproxy_config() {
    echo "📝 Generating HAProxy configuration..."
    
    # Create temporary config file
    local temp_config="/tmp/haproxy.cfg"
    
    cat > "$temp_config" << 'EOF'
global
    daemon
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy

defaults
    mode http
    timeout connect 5000ms
    timeout client 50000ms
    timeout server 50000ms
    option httplog
    option dontlognull

# Stats page
listen stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 30s
    stats admin if TRUE

# Default Kubernetes NodePort (30080) redirections
frontend kubernetes_frontend
    bind *:30080
    mode http
    
    # Default action - if no custom port mapping, proxy to port 80
    default_backend default_backend

backend default_backend
    mode http
    server default_server 127.0.0.1:80 check

EOF

    # Load configuration from config.json and add custom port mappings
    if [ -f "$CONFIG_FILE" ]; then
        echo "📋 Loading app configurations from config.json..."
        
        if command -v jq &> /dev/null; then
            # Get all apps and their configurations
            local apps=$(jq -r '.apps | keys[]' "$CONFIG_FILE")
            
            # Add frontend rules for each app with custom servicePort
            echo "" >> "$temp_config"
            echo "# Custom port redirections based on Host header" >> "$temp_config"
            
            for app in $apps; do
                local service_port=$(jq -r ".apps.\"$app\".servicePort // .defaults.servicePort" "$CONFIG_FILE")
                local domain=$(jq -r ".apps.\"$app\".domain // empty" "$CONFIG_FILE")
                local node_port=$(jq -r ".apps.\"$app\".nodePort // .defaults.nodePort" "$CONFIG_FILE")
                
                # Only create redirection if servicePort is different from 30080
                if [ "$service_port" != "30080" ] && [ "$service_port" != "null" ]; then
                    echo "🔀 Adding redirection for $app: 30080 -> $service_port"
                    
                    # Add ACL and use_backend rules to frontend
                    cat >> "$temp_config" << EOF

# Redirection for $app
frontend ${app}_frontend
    bind *:$service_port
    mode http
    default_backend ${app}_backend

backend ${app}_backend
    mode http
    server ${app}_server 127.0.0.1:$node_port check

EOF
                fi
            done
            
        else
            echo "⚠️ jq not found. Skipping custom port configurations."
        fi
    else
        echo "⚠️ config.json not found. Using default configuration only."
    fi
    
    # Move temp config to actual location
    sudo mv "$temp_config" "$HAPROXY_CONFIG"
    sudo chown root:root "$HAPROXY_CONFIG"
    sudo chmod 644 "$HAPROXY_CONFIG"
    
    echo "✅ HAProxy configuration generated successfully"
}

# Function to validate HAProxy configuration
validate_haproxy_config() {
    echo "🔍 Validating HAProxy configuration..."
    
    if sudo haproxy -c -f "$HAPROXY_CONFIG"; then
        echo "✅ HAProxy configuration is valid"
        return 0
    else
        echo "❌ HAProxy configuration is invalid"
        return 1
    fi
}

# Function to restart HAProxy service
restart_haproxy() {
    echo "🔄 Restarting HAProxy service..."
    
    if sudo systemctl restart haproxy; then
        echo "✅ HAProxy restarted successfully"
        
        # Check if service is running
        if sudo systemctl is-active --quiet haproxy; then
            echo "✅ HAProxy is running"
        else
            echo "❌ HAProxy failed to start"
            return 1
        fi
    else
        echo "❌ Failed to restart HAProxy"
        return 1
    fi
}

# Function to show HAProxy status
show_haproxy_status() {
    echo "📊 HAProxy Status:"
    echo "=================="
    
    if command -v haproxy &> /dev/null; then
        echo "Version: $(haproxy -v | head -1)"
    fi
    
    echo "Service Status:"
    sudo systemctl status haproxy --no-pager -l
    
    echo ""
    echo "Active Ports:"
    sudo netstat -tlnp | grep haproxy || echo "No HAProxy processes found"
    
    echo ""
    echo "Configuration File: $HAPROXY_CONFIG"
    echo "Stats Page: http://localhost:8404/stats"
}

# Main execution
main() {
    echo "🚀 HAProxy Setup and Configuration"
    echo "=================================="
    
    case "${1:-setup}" in
        "install")
            install_haproxy
            ;;
        "config")
            backup_haproxy_config
            generate_haproxy_config
            validate_haproxy_config
            ;;
        "restart")
            restart_haproxy
            ;;
        "status")
            show_haproxy_status
            ;;
        "setup")
            install_haproxy
            backup_haproxy_config
            generate_haproxy_config
            if validate_haproxy_config; then
                restart_haproxy
                show_haproxy_status
            else
                echo "❌ Setup failed due to invalid configuration"
                exit 1
            fi
            ;;
        *)
            echo "Usage: $0 {install|config|restart|status|setup}"
            echo ""
            echo "Commands:"
            echo "  install  - Install HAProxy"
            echo "  config   - Generate HAProxy configuration"
            echo "  restart  - Restart HAProxy service"
            echo "  status   - Show HAProxy status"
            echo "  setup    - Full setup (install + config + restart)"
            exit 1
            ;;
    esac
}

main "$@"