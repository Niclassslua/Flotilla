#!/usr/bin/env bash

# Flotilla Context Sharing Benchmark Launcher
# Direct terminal execution wrapper for provider coding CLIs

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

# Ensure fixture dependencies are installed
if [ ! -d "fixtures/lease-queue/node_modules" ]; then
  echo "Installing fixture dependencies..."
  npm --prefix fixtures/lease-queue install --silent
fi

# Run the TypeScript benchmark harness
npx tsx scripts/run-benchmark.ts "$@"
