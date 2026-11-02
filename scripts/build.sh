#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { print -u2 'Install XcodeGen first.'; exit 1; }
xcodegen generate
xcodebuild -project HomeKitReadOnly.xcodeproj -scheme HomeKitReadOnly \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath build \
  build "$@"
