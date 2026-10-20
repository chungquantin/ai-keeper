#!/bin/bash
# Point the Homebrew cask at a new release: scripts/update-cask.sh <version> <sha256>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?version}"; SHA="${2:?sha256}"
perl -pi -e 's/^(\s*version\s+)".*"/$1"'"$VERSION"'"/; s/^(\s*sha256\s+)".*"/$1"'"$SHA"'"/' Casks/ai-keeper.rb
grep -E '^\s*(version|sha256)' Casks/ai-keeper.rb
