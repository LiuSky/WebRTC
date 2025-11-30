#!/bin/sh

## WebRTC library build script
## Created by Stasel
## BSD-3 License
##
## Example usage: MACOS=true IOS=true BUILD_VP9=true sh build.sh

# Configs
DEBUG="${DEBUG:-false}"
BUILD_VP9="${BUILD_VP9:-false}"
BRANCH="${BRANCH:-master}"
IOS="${IOS:-false}"
MACOS="${MACOS:-false}"
MAC_CATALYST="${MAC_CATALYST:-false}"

OUTPUT_DIR="./out"
XCFRAMEWORK_DIR="out/WebRTC.xcframework"  # 用于存放静态库的 XCFramework 目录
STATIC_LIB_DIR="out/static_libs"  # 静态库输出目录
COMMON_GN_ARGS="is_debug=${DEBUG} rtc_libvpx_build_vp9=${BUILD_VP9} is_component_build=false rtc_include_tests=false rtc_enable_objc_symbol_export=true enable_stripping=true enable_dsyms=false use_lld=true rtc_ios_use_opengl_rendering=true"
PLISTBUDDY_EXEC="/usr/libexec/PlistBuddy"

# Build functions for iOS, macOS, Catalyst (similar to previous steps)
build_iOS() {
    local arch=$1
    local environment=$2
    local gen_dir="${OUTPUT_DIR}/ios-${arch}-${environment}"
    local gen_args="${COMMON_GN_ARGS} target_cpu=\"${arch}\" target_os=\"ios\" target_environment=\"${environment}\" ios_deployment_target=\"12.0\" ios_enable_code_signing=false"
    gn gen "${gen_dir}" --args="${gen_args}"
    gn args --list ${gen_dir} > ${gen_dir}/gn-args.txt
    ninja -C "${gen_dir}" rtc_base rtc_api rtc_video  # Only static library targets
}

build_macOS() {
    local arch=$1
    local gen_dir="${OUTPUT_DIR}/macos-${arch}"
    local gen_args="${COMMON_GN_ARGS} target_cpu=\"${arch}\" target_os=\"mac\""
    gn gen "${gen_dir}" --args="${gen_args}"
    gn args --list ${gen_dir} > ${gen_dir}/gn-args.txt
    ninja -C "${gen_dir}" rtc_base rtc_api rtc_video  # Only static library targets
}

# Step 1: Download and install depot tools
if [ ! -d depot_tools ]; then
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
else
    cd depot_tools
    git pull origin main
    cd ..
fi
export PATH=$(pwd)/depot_tools:$PATH

# Step 2 - Download and build WebRTC
if [ ! -d src ]; then
    fetch --nohooks webrtc_ios
fi
cd src
git fetch --all
git checkout $BRANCH
cd ..
gclient sync --with_branch_heads --with_tags
cd src

# Step 3 - Compile and build all static libraries
rm -rf $OUTPUT_DIR

if [ "$IOS" = true ]; then
    # Only build iOS arm64 (real device)
    build_iOS "arm64" "device"
fi

if [ "$MACOS" = true ]; then
    build_macOS "x64"
    build_macOS "arm64"
fi

# Step 4 - Create XCFramework to include static libs
INFO_PLIST="${XCFRAMEWORK_DIR}/Info.plist"
rm -rf "${XCFRAMEWORK_DIR}"
mkdir "${XCFRAMEWORK_DIR}"
"$PLISTBUDDY_EXEC" -c "Add :CFBundlePackageType string XFWK"  "${INFO_PLIST}"  # Set package type as XFWK
"$PLISTBUDDY_EXEC" -c "Add :XCFrameworkFormatVersion string 1.0"  "${INFO_PLIST}"
"$PLISTBUDDY_EXEC" -c "Add :AvailableLibraries array" "${INFO_PLIST}"

# Add iOS static libs
LIB_COUNT=0
if [[ "$IOS" = true ]]; then
    IOS_LIB_IDENTIFIER="ios-arm64"

    mkdir "${XCFRAMEWORK_DIR}/${IOS_LIB_IDENTIFIER}"
    plist_add_library $LIB_COUNT $IOS_LIB_IDENTIFIER "ios"

    cp -r out/ios-arm64-device/libwebrtc.a "${XCFRAMEWORK_DIR}/${IOS_LIB_IDENTIFIER}"

    plist_add_architecture $LIB_COUNT "arm64"

    LIB_COUNT=$((LIB_COUNT+1))
fi

# Add macOS static libs
if [ "$MACOS" = true ]; then
    MAC_LIB_IDENTIFIER="macos-x86_64_arm64"

    mkdir "${XCFRAMEWORK_DIR}/${MAC_LIB_IDENTIFIER}"
    plist_add_library $LIB_COUNT "${MAC_LIB_IDENTIFIER}" "macos"
    plist_add_architecture $LIB_COUNT "x86_64"
    plist_add_architecture $LIB_COUNT "arm64"

    cp -RP out/macos-x64/libwebrtc.a "${XCFRAMEWORK_DIR}/${MAC_LIB_IDENTIFIER}"
    cp -RP out/macos-arm64/libwebrtc.a "${XCFRAMEWORK_DIR}/${MAC_LIB_IDENTIFIER}"

    LIB_COUNT=$((LIB_COUNT+1))
fi

# Add macOS Catalyst static libs
if [ "$MAC_CATALYST" = true ]; then
    CATALYST_LIB_IDENTIFIER="ios-x86_64_arm64-maccatalyst"

    mkdir "${XCFRAMEWORK_DIR}/${CATALYST_LIB_IDENTIFIER}"
    plist_add_library $LIB_COUNT "${CATALYST_LIB_IDENTIFIER}" "ios" "maccatalyst"
    plist_add_architecture $LIB_COUNT "x86_64"
    plist_add_architecture $LIB_COUNT "arm64"

    cp -RP out/catalyst-x64/libwebrtc.a "${XCFRAMEWORK_DIR}/${CATALYST_LIB_IDENTIFIER}"
    cp -RP out/catalyst-arm64/libwebrtc.a "${XCFRAMEWORK_DIR}/${CATALYST_LIB_IDENTIFIER}"

    LIB_COUNT=$((LIB_COUNT+1))
fi

# Step 5 - Add license file to the XCFramework
cp LICENSE ${XCFRAMEWORK_DIR}

# Step 6 - Archive the XCFramework
cd out
NOW=$(date -u +"%Y-%m-%dT%H-%M-%S")
OUTPUT_NAME=WebRTC-static-$NOW.xcframework.zip
zip --symlinks -r $OUTPUT_NAME WebRTC.xcframework/

# Step 7 - Calculate SHA256 checksum
CHECKSUM=$(shasum -a 256 $OUTPUT_NAME | awk '{ print $1 }')
COMMIT_HASH=$(git rev-parse HEAD)

echo "{ \"file\": \"${OUTPUT_NAME}\", \"checksum\": \"${CHECKSUM}\", \"commit\": \"${COMMIT_HASH}\", \"branch\": \"${BRANCH}\" }" > metadata.json
cat metadata.json

