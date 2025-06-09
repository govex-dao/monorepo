# Make the deployment script executable
chmod +x govex-deploy.sh

# Set admin email as an environment variable (only needed for nginx/SSL setup)
# Skip this step if you're only running the deploy command
export ADMIN_EMAIL=your.email@example.com

# Run full deployment (removes existing repo, clones fresh, deploys both backend and frontend)
./govex-deploy.sh deploy

# Frontend only
chmod +x redeploy-frontend-only.sh
./redeploy-frontend-only.sh

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

# Getting all issues to evaluate next one
```
gh issue list --state open --limit 1000 --json number,title,body,state,url,createdAt,author,labels,assignees > open_issues_detailed.json
```

```
for my futarchy platform in dog fooding stage
give me two most important tickets from here
```