#!/bin/bash
# 一键构建 YierPet.app（只需 Xcode Command Line Tools，无需完整 Xcode）
set -e
cd "$(dirname "$0")"

APP=build/YierPet.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "正在编译..."
swiftc -O Sources/YierPet/*.swift -o "$APP/Contents/MacOS/YierPet"

cp Info.plist "$APP/Contents/Info.plist"
cp Sources/YierPet/Resources/spritesheet.webp "$APP/Contents/Resources/"

# 表情包资源（一二/布布/合体三套帧序列）
if [ -d Assets/Packs ]; then
  rm -rf "$APP/Contents/Resources/Packs"
  cp -R Assets/Packs "$APP/Contents/Resources/Packs"
fi

echo "构建完成：$APP"
echo "启动：open $APP"
