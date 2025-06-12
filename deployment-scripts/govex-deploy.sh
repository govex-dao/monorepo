GNU nano 8.1                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              redeploy.sh                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       
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
        pm2 stop frontend 2>/dev/null || echo "Frontend process not running."
        pm2 stop backend 2>/dev/null || echo "Backend process not running."
        pm2 stop bot 2>/dev/null || echo "Bot process not running."
        pm2 delete frontend 2>/dev/null || echo "No frontend process to delete."
        pm2 delete backend 2>/dev/null || echo "No backend process to delete."
        pm2 delete bot 2>/dev/null || echo "No bot process to delete."
        pm2 save
        echo "Removing project directory..."
        sudo rm -rf "/root/monorepo" || { echo "Failed to remove project directory."; exit 1; }
    else
        echo "No existing project directory found. Skipping removal."
    fi

    echo "=== Cloning Govex Repository ==="
    git clone git@github.com:govex-dao/monorepo.git /root/monorepo || { echo "Failed to clone repository."; exit 1; }

    echo "=== Deploying Backend ==="
    BACKEND_DIR="/root/monorepo/backend"
    if [ -d "$BACKEND_DIR" ]; then
        cd "$BACKEND_DIR" || { echo "Failed to enter backend directory."; exit 1; }
        pnpm install || { echo "Failed to install backend dependencies."; exit 1; }
        npx prisma generate
        echo "Enforcing WAL mode on SQLite database..."
        sqlite3 dev.db "PRAGMA journal_mode=WAL;" || { echo "Failed to enable WAL mode."; exit 1; }

        pm2 start "pnpm dev:prod" --name backend || { echo "Failed to start backend."; exit 1; }
        pm2 save || { echo "Failed to save PM2 backend process."; exit 1; }
        
        echo "Starting Bot service..."
        pm2 start "pnpm bot:prod" --name bot || { echo "Failed to start bot."; exit 1; }
        pm2 save || { echo "Failed to save PM2 bot process."; exit 1; }
    else
        echo "Backend directory not found. Skipping backend deployment."
    fi

    echo "=== Deploying Frontend ==="
    FRONTEND_DIR="/root/monorepo/frontend"
    if [ -d "$FRONTEND_DIR" ]; then
        cd "$FRONTEND_DIR" || { echo "Failed to enter frontend directory."; exit 1; }
        pnpm install --ignore-workspace || { echo "Failed to install frontend dependencies."; exit 1; }
        pnpm vite build
        pm2 start "serve -s dist -l 5173" --name frontend
        pm2 save || { echo "Failed to save PM2 frontend process."; exit 1; }
    else
        echo "Frontend directory not found. Skipping frontend deployment."
    fi

    echo "=== Govex Reinstallation and Deployment Complete ==="
}

function setup_nginx_and_ssl() {
    echo "=== Setting Up Nginx and SSL ==="
    sudo apt install -y nginx certbot python3-certbot-nginx
    sudo tee /etc/nginx/sites-available/default > /dev/null <<EOF
server {
    listen 80;
    server_name www.govex.ai govex.ai;

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
    deploy)
        reinstall_and_deploy
        ;;
    all)
        update_system
        setup_swap
        install_dependencies
        install_node_and_pnpm
        reinstall_and_deploy    
        setup_nginx_and_ssl
        ;;
    *)
        echo "Usage: $0 {deploy|all}"
        ;;
    esac
}

main "$@"