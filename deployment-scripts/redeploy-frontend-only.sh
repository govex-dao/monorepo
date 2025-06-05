#!/bin/bash
set -e

# Variables
DOMAIN="www.govex.ai"
ROOT_DOMAIN="govex.ai"
FRONTEND_PORT=5173
PROJECT_DIR="/root/monorepo"

function update_frontend_code_only() {
    echo "=== Updating Frontend Code Only ==="
    if [ -d "$PROJECT_DIR" ]; then
        cd "$PROJECT_DIR"
        
        # Fetch latest changes without merging
        echo "Fetching latest changes from repository..."
        git fetch origin
        
        # Only checkout frontend directory from the latest commit
        echo "Updating only frontend files..."
        git checkout origin/main -- frontend/ || git checkout origin/master -- frontend/ || { 
            echo "Failed to update frontend files"; 
            exit 1; 
        }
        
        echo "Frontend files updated, backend files untouched"
        
        # Show what was updated
        echo "Recently updated frontend files:"
        git diff --name-only HEAD@{1} HEAD -- frontend/ | head -10
    else
        echo "Error: Project directory not found at $PROJECT_DIR"
        exit 1
    fi
}

function deploy_frontend_only() {
    echo "=== Deploying Frontend Only ==="
    
    # Stop existing frontend process
    echo "Stopping frontend PM2 process..."
    pm2 stop frontend 2>/dev/null || echo "Frontend process not running."
    
    FRONTEND_DIR="$PROJECT_DIR/frontend"
    if [ -d "$FRONTEND_DIR" ]; then
        cd "$FRONTEND_DIR" || { echo "Failed to enter frontend directory."; exit 1; }
        
        echo "Cleaning old build and dependencies..."
        rm -rf dist/ node_modules package-lock.json pnpm-lock.yaml
        
        echo "Installing frontend dependencies fresh..."
        pnpm install --ignore-workspace || { echo "Failed to install frontend dependencies."; exit 1; }
        
        echo "Building frontend..."
        pnpm vite build || { echo "Failed to build frontend."; exit 1; }
        
        echo "Restarting frontend with PM2..."
        pm2 delete frontend 2>/dev/null || echo "No frontend process to delete."
        pm2 start "serve -s dist -l 5173" --name frontend || { echo "Failed to start frontend."; exit 1; }
        pm2 save || { echo "Failed to save PM2 frontend process."; exit 1; }
        
        echo "=== Frontend Deployment Complete ==="
        echo "Frontend is running on port $FRONTEND_PORT"
        pm2 status frontend
    else
        echo "Error: Frontend directory not found at $FRONTEND_DIR"
        exit 1
    fi
}

function check_dependencies() {
    echo "=== Checking Dependencies ==="
    
    # Check if git is installed
    if ! command -v git &> /dev/null; then
        echo "Error: git is not installed."
        exit 1
    fi
    
    # Check if pnpm is installed
    if ! command -v pnpm &> /dev/null; then
        echo "Error: pnpm is not installed. Please install it first."
        exit 1
    fi
    
    # Check if PM2 is installed
    if ! command -v pm2 &> /dev/null; then
        echo "Error: PM2 is not installed. Installing PM2..."
        pnpm add -g pm2
    fi
    
    # Check if serve is installed
    if ! pnpm list -g serve &> /dev/null; then
        echo "Installing serve globally..."
        pnpm add -g serve
    fi
}

function show_backend_status() {
    echo "=== Current Backend Status ==="
    echo "Backend files on disk: NOT modified"
    echo "Backend PM2 process status:"
    pm2 status backend 2>/dev/null || echo "Backend process not found"
    echo ""
}

# Main Script Logic
function main() {
    echo "=== Frontend-Only Deployment Script ==="
    echo "This script will:"
    echo "  ✓ Update ONLY frontend files from git"
    echo "  ✓ Leave backend files untouched on disk"
    echo "  ✓ Reinstall frontend dependencies fresh"
    echo "  ✓ Rebuild and redeploy frontend"
    echo "  ✗ NOT touch the database"
    echo "  ✗ NOT modify backend files"
    echo "  ✗ NOT restart backend process"
    echo ""
    
    # Show current status
    show_backend_status
    
    # Confirm before proceeding
    read -p "Continue with frontend-only deployment? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled."
        exit 0
    fi
    
    # Run deployment
    check_dependencies
    update_frontend_code_only
    deploy_frontend_only
    
    echo ""
    echo "=== Deployment Summary ==="
    echo "✓ Frontend code updated from git (backend files untouched)"
    echo "✓ Frontend dependencies reinstalled fresh"
    echo "✓ Frontend rebuilt and redeployed"
    echo "✓ Backend files on disk: unchanged"
    echo "✓ Backend process: still running old code"
    echo "✓ Database: untouched"
    echo ""
    echo "Useful commands:"
    echo "  pm2 status          - Check all processes"
    echo "  pm2 logs frontend   - View frontend logs"
    echo "  pm2 logs backend    - View backend logs"
    echo ""
    
    # Final status check
    show_backend_status
}

# Run the script
main