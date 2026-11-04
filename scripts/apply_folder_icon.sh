#!/bin/bash
# Apply custom Agent Control Center folder icon on macOS
# Usage: ./scripts/apply_folder_icon.sh [folder_path] [--3d]

TARGET_FOLDER="${1:-.}"
USE_3D=false

if [ "$1" == "--3d" ] || [ "$2" == "--3d" ]; then
  USE_3D=true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [ "$USE_3D" = true ]; then
  ICON_PATH="$ROOT_DIR/assets/icons/folder_icon_3d.icns"
  echo "Applying 3D Folder Icon..."
else
  ICON_PATH="$ROOT_DIR/assets/icons/folder_icon.icns"
  echo "Applying Front Folder Icon..."
fi

if [ ! -f "$ICON_PATH" ]; then
  echo "Error: Icon file not found at $ICON_PATH"
  exit 1
fi

TARGET_ABS=$(cd "$TARGET_FOLDER" 2>/dev/null && pwd || echo "$TARGET_FOLDER")

swift -e "
import Cocoa

let iconPath = \"$ICON_PATH\"
let targetFolder = \"$TARGET_ABS\"

guard let image = NSImage(contentsOfFile: iconPath) else {
    print(\"Failed to load icon from: \(iconPath)\")
    exit(1)
}

let success = NSWorkspace.shared.setIcon(image, forFile: targetFolder, options: [])
if success {
    print(\"✅ Successfully applied custom folder icon to: \(targetFolder)\")
} else {
    print(\"❌ Failed to set icon for: \(targetFolder)\")
    exit(1)
}
"
