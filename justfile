set shell := ["/bin/bash", "-c"]

# List available commands
help:
    @just --list

# Format code
format:
    swift format --in-place --recursive Sources Tests

# Lint code
lint:
    swift format lint --recursive Sources Tests
    swiftlint

# Run tests
test:
    scripts/generate-version.sh
    swift package resolve
    scripts/patch-deps.sh
    swift test

# Build universal release binary into bin/
build:
    scripts/generate-version.sh
    swift package resolve
    scripts/patch-deps.sh
    scripts/build-universal.sh

# Build (debug) imsg
build-debug:
    scripts/generate-version.sh
    swift package resolve
    scripts/patch-deps.sh
    swift build -c debug --product imsg

# Run imsg (builds if needed)
run *args: build-debug
    ./.build/debug/imsg "$@"

# Run imsg in RPC mode (fast, no build check)
rpc *args:
    ./.build/debug/imsg rpc "$@"

# Build (debug) and launch the HTTP server on 127.0.0.1:3939
serve *args: build-debug
    ./.build/debug/imsg serve "$@"

# Clean the project
clean:
    swift package clean
