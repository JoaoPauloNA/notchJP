#!/bin/zsh
set -euo pipefail
repo_dir=${0:A:h:h}
build_dir=${NOTCH_DERIVED_DATA:-$repo_dir/build/public}
xcodebuild -project "$repo_dir/notchi/notchi.xcodeproj" -scheme notchi \
  -configuration Release -derivedDataPath "$build_dir" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO build
codesign --force --deep --sign "${NOTCH_SIGN_IDENTITY:--}" "$build_dir/Build/Products/Release/notchJP.app"
codesign --verify --deep --strict "$build_dir/Build/Products/Release/notchJP.app"
echo "Built: $build_dir/Build/Products/Release/notchJP.app"
