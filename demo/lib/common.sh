#!/usr/bin/env bash
# Shared by the demo generators. Not meant to be run on its own.

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$DEMO_DIR/.." && pwd)"
WORK_DIR="$DEMO_DIR/work"

export DEMO_DIR REPO_DIR WORK_DIR
