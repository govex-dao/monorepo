# Make the deployment script executable
chmod +x govex-deploy.sh

# Set admin email as an environment variable (only needed for nginx/SSL setup)
# Skip this step if you're only running the deploy command
export ADMIN_EMAIL=your.email@example.com

# Run full deployment (removes existing repo, clones fresh, deploys both backend and frontend)
./govex-deploy.sh deploy

# Optional: For manually building and serving the frontend statically
cd /root/monorepo/frontend
pnpm vite build
serve -s dist -l 5173

# Generate SSH key for GitHub access (if needed)
# This creates a new SSH key for connecting to GitHub
ssh-keygen -t ed25519 -C "your_email@example.com"

# Return to home directory
cd ~

# Run all setup steps in a new VM:
# ./govex-deploy.sh all

# Helper cmds
```
tree -I "node_modules" > repo_structure.txt
```