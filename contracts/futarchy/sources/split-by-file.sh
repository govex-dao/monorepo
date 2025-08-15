#!/bin/bash

# --- Configuration ---
# The maximum number of lines per output file.
LIMIT=10000
# The pattern to search for (e.g., '*.move', '*.log', etc.)
FILE_PATTERN='*.move'
# The prefix for the output files (e.g., 'move_chunk_', 'output_part_')
OUTPUT_PREFIX="move_chunk_"
# --- End Configuration ---

# Initialize counters
current_lines=0
file_index=1
output_file="${OUTPUT_PREFIX}${file_index}.txt"

# Clean up any old chunk files before starting
echo "Removing old chunk files: ${OUTPUT_PREFIX}*.txt"
rm -f "${OUTPUT_PREFIX}"*.txt
echo "Starting..."

# Use find with -print0 and a while read loop.
# This is the safest way to handle filenames with spaces or special characters.
find . -type f -name "$FILE_PATTERN" -print0 | while IFS= read -r -d '' filepath; do
  # Get the number of lines in the current file we're processing
  lines_in_file=$(wc -l < "$filepath")

  # If the current output file is not empty AND adding the new file
  # would push it over the limit, we start a new output file.
  if [[ $current_lines -gt 0 && $((current_lines + lines_in_file)) -gt $LIMIT ]]; then
    echo "Limit reached for $output_file. It has $current_lines lines."
    ((file_index++))
    output_file="${OUTPUT_PREFIX}${file_index}.txt"
    current_lines=0
    echo "Switching to new file: $output_file"
  fi

  # Append the content of the found file to the current output file
  cat "$filepath" >> "$output_file"

  # Update the line count for the current output file
  current_lines=$((current_lines + lines_in_file))
done

echo "----------------------------------------"
echo "Processing complete."
echo "Created $file_index chunk file(s)."
echo "Final file '$output_file' contains $current_lines lines."