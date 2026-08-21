#!/bin/bash
set -e
DEST="Flotilla/Resources/MaterialIcons"
mkdir -p "$DEST"

ICONS=(
    folder folder-open folder-src folder-src-open folder-test folder-test-open
    folder-dist folder-dist-open folder-node folder-node-open folder-packages
    folder-git folder-github folder-images folder-docs folder-config
    folder-scripts folder-components folder-views folder-hook folder-assets
    swift typescript typescript-def javascript react react_ts python
    rust go c cpp csharp java kotlin php ruby lua dart
    zig vue svelte graphql proto html css sass json yaml
    toml markdown console database docker git lock key nodejs
    settings tune document image audio video zip pdf xml svg
    table font robot visualstudio prettier eslint vite next
    tailwind webpack jest npm gemfile cargo editorconfig
)

for icon in "${ICONS[@]}"; do
    echo "url = \"https://raw.githubusercontent.com/PKief/vscode-material-icon-theme/main/icons/${icon}.svg\"" >> /tmp/curl_icons.txt
    echo "output = \"${DEST}/${icon}.svg\"" >> /tmp/curl_icons.txt
done

curl -s -K /tmp/curl_icons.txt --parallel --parallel-max 16
rm /tmp/curl_icons.txt
echo "Downloaded $(ls -1 "$DEST" | wc -l) SVG icons into $DEST"
