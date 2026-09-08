#!/bin/bash
# Script to add the workflow file to GitHub repository

echo "Copy the content below and paste it into GitHub:"
echo "1. Go to https://github.com/mikedzikowski/falcon-aca-test"
echo "2. Click 'Add file' -> 'Create new file'"
echo "3. Filename: .github/workflows/falcon-aca-demo.yml"
echo "4. Copy/paste the content from the workflow file"
echo ""
echo "Workflow file location: $(pwd)/.github/workflows/falcon-aca-demo.yml"
echo ""
echo "=== WORKFLOW CONTENT START ==="
cat .github/workflows/falcon-aca-demo.yml
echo "=== WORKFLOW CONTENT END ==="