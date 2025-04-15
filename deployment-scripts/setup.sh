#!/bin/bash
set -e

# Variables
DOMAIN="www.govex.ai"
ROOT_DOMAIN="govex.ai"
FRONTEND_PORT=5173
BACKEND_PORT=3000
SUI_NETWORK="testnet"

# Check for required environment variables
if [ -z "${ADMIN_EMAIL}" ]; then
  echo "Error: ADMIN_EMAIL environment variable is required"
  exit 1
fi

PROJECT_DIR="/root/monorepo"

# Helper Functions
function update_system() {
    echo "=== Updating System ==="
    sudo apt update -y && sudo apt upgrade -y
}

function setup_swap() {
    echo "=== Setting Up Swap ==="
    if [ -f /swapfile ] && swapon --show | grep -q '/swapfile'; then
        echo "Swap is already set up. Skipping..."
    else
        echo "Creating and activating 2 GB swap file..."
        sudo fallocate -l 2G /swapfile
        sudo chmod 600 /swapfile
        sudo mkswap /swapfile
        sudo swapon /swapfile
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
        free -h
    fi
}

function install_dependencies() {
    echo "=== Installing Required Packages ==="
    sudo apt install -y curl git software-properties-common ufw
}

function install_node_and_pnpm() {
    echo "=== Installing Node.js and pnpm ==="
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    sudo apt install -y nodejs
    npm install -g pnpm
}

function reinstall_and_deploy() {
    echo "=== Removing Existing Govex Project ==="
    if [ -d "/root/monorepo" ]; then
        echo "Stopping PM2 processes..."
        pm2 stop frontend || echo "Frontend process not running."
        pm2 stop backend || echo "Backend process not running."
        pm2 delete frontend || echo "No frontend process to delete."
        pm2 delete backend || echo "No backend process to delete."
        pm2 save
        echo "Removing project directory..."
        rm -rf "/root/monorepo"
    else
        echo "No existing project directory found. Skipping removal."
    fi

    echo "=== Cloning Govex Repository ==="
    git clone https://github.com/govex-dao/monorepo.git /root/monorepo

    echo "=== Deploying Backend ==="
    cd "$PROJECT_DIR/api"
    pnpm install
    pnpm db:setup:dev
    pm2 start "pnpm dev" --name backend
    pm2 save

    echo "=== Deploying Frontend ==="
    cd "$PROJECT_DIR/frontend"
    pnpm install --ignore-workspace
    pm2 start "pnpm dev --host 127.0.0.1" --name frontend
    pm2 save

    echo "=== Govex Reinstallation and Deployment Complete ==="
}

function deploy_frontend() {
    echo "=== Deploying Frontend ==="
    cd "$PROJECT_DIR/frontend"
    git pull origin main # Pull the latest frontend code (adjust branch as needed)
    pnpm install --ignore-workspace
    pm2 restart frontend || pm2 start "pnpm dev --host 127.0.0.1" --name frontend
    pm2 save
}

function deploy_backend() {
    echo "=== Deploying Backend ==="
    cd "$PROJECT_DIR/api"
    git pull origin main # Pull the latest backend code (adjust branch as needed)
    pnpm install
    pnpm db:setup:dev
    pm2 restart backend || pm2 start "pnpm dev" --name backend
    pm2 save
}

function setup_nginx_and_ssl() {
    echo "=== Setting Up Nginx and SSL ==="
    sudo apt install -y nginx certbot python3-certbot-nginx
    sudo tee /etc/nginx/sites-available/default > /dev/null <<EOF
server {
    listen 80;
    server_name www.govex.ai govex.ai;
    server_tokens off;

    if (\$host = govex.ai) {
        return 301 https://www.govex.ai\$request_uri;
    }

    location / {
        proxy_pass http://127.0.0.1:5173;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:3000/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
    sudo nginx -t
    sudo systemctl reload nginx

    echo "Obtaining SSL certificates..."
    sudo certbot --nginx -d www.govex.ai -d govex.ai --non-interactive --agree-tos -m "${ADMIN_EMAIL}"
    sudo certbot renew --dry-run
    sudo systemctl reload nginx
    echo "Nginx and SSL setup complete."
}

# Main Script Logic
function main() {
    case $1 in
    system)
        update_system
        ;;
    swap)
        setup_swap
        ;;
    dependencies)
        install_dependencies
        install_node_and_pnpm
        ;;
    deploy)
        reinstall_and_deploy
        ;;
    frontend)
        deploy_frontend
        ;;
    backend)
        deploy_backend
        ;;
    nginx)
        setup_nginx_and_ssl
        ;;
    all)
        update_system
        setup_swap
        install_dependencies
        install_node_and_pnpm
        deploy_backend
        deploy_frontend
        setup_nginx_and_ssl
        ;;
    *)
        echo "Usage: $0 {system|swap|dependencies|frontend|backend|nginx|all}"
        ;;
    esac
}

main "$@"
