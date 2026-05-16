#!/usr/bin/env bash
# Point this clone's git hooks at the shared scripts/hooks dir.
# Run once after cloning.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath scripts/hooks
echo "core.hooksPath -> scripts/hooks"
