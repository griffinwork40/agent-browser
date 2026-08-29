#!/bin/sh
# Build and run the WKWebView spike
# Usage: sh build.sh
set -e
cd "$(dirname "$0")"
echo "Compiling BrowserSpike.swift..."
swiftc -framework WebKit -framework AppKit -o BrowserSpike BrowserSpike.swift
echo "Build succeeded. Running..."
./BrowserSpike
