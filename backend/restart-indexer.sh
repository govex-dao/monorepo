#!/bin/bash

# Function to handle cleanup on script exit
cleanup() {
    echo "Cleaning up..."
    # Kill any running indexer processes
    pkill -f "pnpm indexer"
    exit
}

# Set up trap for script termination
trap cleanup SIGINT SIGTERM

echo "Starting indexer auto-restart script..."

while true; do
    echo "$(date): Starting indexer..."
    
    # Start the indexer in the background
    pnpm indexer &
    
    # Store the PID
    INDEXER_PID=$!
    
    # Wait for 5 seconds
    sleep 9
    
    # Kill the indexer process
    echo "$(date): Stopping indexer..."
    kill $INDEXER_PID 2>/dev/null
    
    # Make sure any child processes are also killed
    pkill -f "pnpm indexer"
    
    # Small pause before next restart
    sleep 2
done