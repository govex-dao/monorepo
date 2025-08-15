#!/bin/bash

ENV_FILE="./scripts/.env"

get_env_value() {
    local key="$1"
    local value=""
    if [ -f "$ENV_FILE" ]; then
        value=$(grep "^${key}=" "$ENV_FILE" | cut -d '=' -f2- | tr -d '"')
    fi
    echo "$value"
}

if ! command -v bun &> /dev/null; then
    echo "Bun is not installed. Installing..."
    curl -fsSL https://bun.sh/install | bash
    echo "Bun installed successfully. Please restart your shell or run 'source ~/.bashrc' (or equivalent) if needed."
fi


if [ ! -d "./scripts/node_modules" ]; then
    echo "node_modules not found. Installing dependencies using bun..."
    (cd ./scripts && bun install)
else
    echo "node_modules directory exists. Skipping dependency installation."
fi

if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from $ENV_FILE..."

    KEY=$(get_env_value "KEY")
    CLI_PATH=$(get_env_value "CLI_PATH")
    PACKAGES_PATH=$(get_env_value "PACKAGES_PATH")
    NETWORK=$(get_env_value "NETWORK")

    # Prompt for any missing values
    [ -z "$KEY" ] && read -p "Enter your private key (KEY): " KEY
    [ -z "$CLI_PATH" ] && read -p "Enter the CLI path (default: $(which sui)): " CLI_PATH
    CLI_PATH=${CLI_PATH:-$(which sui)}

    [ -z "$PACKAGES_PATH" ] && read -p "Enter the packages path (default: ../packages): " PACKAGES_PATH
    PACKAGES_PATH=${PACKAGES_PATH:-../packages}

    [ -z "$NETWORK" ] && read -p "Enter the network (default: localnet): " NETWORK
    NETWORK=${NETWORK:-localnet}
else
    echo "No .env file found. Using script default values without prompting."

    KEY=""
    CLI_PATH="$(which sui)"
    PACKAGES_PATH="../packages"
    NETWORK="localnet"
fi

export KEY
export CLI_PATH
export PACKAGES_PATH
export NETWORK

echo "Environment variables set:"
echo "KEY=[HIDDEN]"
echo "CLI_PATH=$CLI_PATH"
echo "PACKAGES_PATH=$PACKAGES_PATH"
echo "NETWORK=$NETWORK"

echo "Running bun run publish..."
(cd ./scripts && bun run publish)