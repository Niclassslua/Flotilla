#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="${SRCROOT:-$(cd "$SCRIPT_DIRECTORY/.." && pwd)}"
RAW_SCREENSHOT_DIRECTORY="${UI_VOCABULARY_RAW_DIR:-$HOME/Library/Containers/com.niclassslua.FlotillaUITests.xctrunner/Data/Documents/flotilla-vocab-shots}"

xcrun swift "$REPOSITORY_ROOT/Scripts/update-ui-vocabulary-screenshots.swift" \
    --source "$RAW_SCREENSHOT_DIRECTORY" \
    --destination "$REPOSITORY_ROOT/docs/images/ui-vocabulary"
