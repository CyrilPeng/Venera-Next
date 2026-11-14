#!/usr/bin/env bash
set -euo pipefail

if [[ "$CHANGES_RESULT" != "success" || \
      ("$PLATFORM_REQUIRED" == "true" && ("$ANDROID_RESULT" != "success" || "$WINDOWS_RESULT" != "success")) || \
      ("$DESKTOP_REQUIRED" == "true" && "$DESKTOP_RESULT" != "success") || \
      ("$ANDROID_RESULT" != "success" && "$ANDROID_RESULT" != "skipped") || \
      ("$WINDOWS_RESULT" != "success" && "$WINDOWS_RESULT" != "skipped") || \
      ("$DESKTOP_RESULT" != "success" && "$DESKTOP_RESULT" != "skipped") ]]; then
  echo "平台冒烟构建未通过：changes=$CHANGES_RESULT android=$ANDROID_RESULT windows=$WINDOWS_RESULT desktop=$DESKTOP_RESULT"
  exit 1
fi
echo "平台冒烟构建通过：Android 手机版与 TV 版=$ANDROID_RESULT Windows=$WINDOWS_RESULT Linux／macOS／iOS=$DESKTOP_RESULT"
