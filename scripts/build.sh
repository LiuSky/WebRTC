#!/bin/sh

## WebRTC 库构建脚本
## 创建者：Stasel
## BSD-3 许可证
##
## 使用示例：MACOS=true IOS=true BUILD_VP9=true sh build.sh

# 配置项
DEBUG="${DEBUG:-false}"               # 调试模式，默认为 false
BUILD_VP9="${BUILD_VP9:-false}"       # 是否构建 VP9，默认为 false
BRANCH="${BRANCH:-master}"            # 分支，默认为 master
IOS="${IOS:-false}"                   # 是否构建 iOS，默认为 false
MACOS="${MACOS:-false}"               # 是否构建 macOS，默认为 false
MAC_CATALYST="${MAC_CATALYST:-false}" # 是否构建 Catalyst，默认为 false

OUTPUT_DIR="./out"                   # 输出目录
XCFRAMEWORK_DIR="out/WebRTC.xcframework"  # XCFramework 输出目录
COMMON_GN_ARGS="is_debug=${DEBUG} rtc_libvpx_build_vp9=${BUILD_VP9} is_component_build=false rtc_include_tests=false rtc_enable_objc_symbol_export=true enable_stripping=true enable_dsyms=false use_lld=true rtc_ios_use_opengl_rendering=true"  # GN 构建通用参数
PLISTBUDDY_EXEC="/usr/libexec/PlistBuddy"  # PlistBuddy 执行路径

# 构建 iOS 真机架构
build_iOS() {
    local arch=$1
    local environment=$2
    local gen_dir="${OUTPUT_DIR}/ios-${arch}-${environment}"
    local gen_args="${COMMON_GN_ARGS} target_cpu=\"${arch}\" target_os=\"ios\" target_environment=\"${environment}\" ios_deployment_target=\"12.0\" ios_enable_code_signing=false"
    gn gen "${gen_dir}" --args="${gen_args}"  # 生成构建文件
    gn args --list ${gen_dir} > ${gen_dir}/gn-args.txt  # 输出 GN 配置
    ninja -C "${gen_dir}" framework_objc || exit 1  # 使用 ninja 构建框架
}

# 构建 macOS 框架
build_macOS() {
    local arch=$1
    local gen_dir="${OUTPUT_DIR}/macos-${arch}"
    local gen_args="${COMMON_GN_ARGS} target_cpu=\"${arch}\" target_os=\"mac\""
    gn gen "${gen_dir}" --args="${gen_args}"  # 生成构建文件
    gn args --list ${gen_dir} > ${gen_dir}/gn-args.txt  # 输出 GN 配置
    ninja -C "${gen_dir}" mac_framework_objc || exit 1  # 使用 ninja 构建框架
}

# Catalyst 构建暂时无法正常工作，参考链接： https://groups.google.com/g/discuss-webrtc/c/VZXS4V4mSY4
build_catalyst() {
    local arch=$1
    local gen_dir="${OUTPUT_DIR}/catalyst-${arch}"
    local gen_args="${COMMON_GN_ARGS} target_cpu=\"${arch}\" target_environment=\"catalyst\" target_os=\"ios\" ios_deployment_target=\"14.0\" ios_enable_code_signing=false"
    gn gen "${gen_dir}" --args="${gen_args}"  # 生成构建文件
    gn args --list ${gen_dir} > ${gen_dir}/gn-args.txt  # 输出 GN 配置
    ninja -C "${gen_dir}" framework_objc || exit 1  # 使用 ninja 构建框架
}

# 向 Info.plist 中添加库信息
plist_add_library() {
    local index=$1
    local identifier=$2
    local platform=$3
    local platform_variant=$4
    "$PLISTBUDDY_EXEC" -c "Add :AvailableLibraries: dict"  "${INFO_PLIST}"
    "$PLISTBUDDY_EXEC" -c "Add :AvailableLibraries:${index}:LibraryIdentifier string ${identifier}"  "${INFO_PLIST}"
    "$PLISTBUDDY_EXEC" -c "Add :AvailableLibraries:${index}:LibraryPath string WebRTC.framework"  "${INFO_PLIST}"
    "$PLISTBUDDY_EXEC" -c "Add :AvailableLibraries:${index}:SupportedArchitectures array"  "${INFO_PLIST}"
    "$PLISTBUDDY_EXEC" -c "Add :AvailableLibraries:${index}:SupportedPlatform string ${platform}"  "${INFO_PLIST}"
    if [ ! -z "$platform_variant" ]; then
        "$PLISTBUDDY_EXEC" -c "Add :AvailableLibraries:${index}:SupportedPlatformVariant string ${platform_variant}" "${INFO_PLIST}"
    fi
}

# 向 Info.plist 中添加架构信息
plist_add_architecture() {
    local index=$1
    local arch=$2
    "$PLISTBUDDY_EXEC" -c "Add :AvailableLibraries:${index}:SupportedArchitectures: string ${arch}"  "${INFO_PLIST}"
}

# 第 1 步：下载并安装 depot tools
if [ ! -d depot_tools ]; then
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
else
    cd depot_tools
    git pull origin main
    cd ..
fi
export PATH=$(pwd)/depot_tools:$PATH

# 第 2 步 - 下载并构建 WebRTC
if [ ! -d src ]; then
    fetch --nohooks webrtc_ios
fi
cd src
git fetch --all
git checkout $BRANCH
cd ..
gclient sync --with_branch_heads --with_tags
cd src

# 第 3 步 - 编译并构建所有框架
rm -rf $OUTPUT_DIR

# 只构建 iOS 真机 arm64 架构
if [ "$IOS" = true ]; then
    build_iOS "arm64" "device"  # 构建 iOS 真机架构
fi

# 只构建 macOS 框架
if [ "$MACOS" = true ]; then
    build_macOS "x64"
    build_macOS "arm64"
fi

# 第 4 步 - 手动创建 XCFramework。
# 我们无法使用 xcodebuild `-xcodebuild -create-xcframework`，因为会出现以下错误：
# "Both ios-arm64-simulator and ios-x86_64-simulator represent two equivalent library definitions."
# 因此我们手动使用 lipo 工具将多个架构的二进制文件合并成 XCFramework。
# 还要使用 plistbuddy 创建 XCFramework 的 plist 文件

INFO_PLIST="${XCFRAMEWORK_DIR}/Info.plist"
rm -rf "${XCFRAMEWORK_DIR}"
mkdir "${XCFRAMEWORK_DIR}"
"$PLISTBUDDY_EXEC" -c "Add :CFBundlePackageType string XFWK"  "${INFO_PLIST}"
"$PLISTBUDDY_EXEC" -c "Add :XCFrameworkFormatVersion string 1.0"  "${INFO_PLIST}"
"$PLISTBUDDY_EXEC" -c "Add :AvailableLibraries array" "${INFO_PLIST}"

# 第 5 步.1 - 添加 iOS 库到 XCFramework
LIB_COUNT=0
if [[ "$IOS" = true ]]; then

    IOS_LIB_IDENTIFIER="ios-arm64"  # 只保留 iOS 真机 arm64 架构
    mkdir "${XCFRAMEWORK_DIR}/${IOS_LIB_IDENTIFIER}"
    LIB_IOS_INDEX=0
    plist_add_library $LIB_IOS_INDEX $IOS_LIB_IDENTIFIER "ios"

    cp -r out/ios-arm64-device/WebRTC.framework "${XCFRAMEWORK_DIR}/${IOS_LIB_IDENTIFIER}"

    LIPO_IOS_FLAGS="out/ios-arm64-device/WebRTC.framework/WebRTC"

    plist_add_architecture $LIB_IOS_INDEX "arm64"

    lipo -create -output  "${XCFRAMEWORK_DIR}/${IOS_LIB_IDENTIFIER}/WebRTC.framework/WebRTC" ${LIPO_IOS_FLAGS}

    # 代码签名模拟器框架（仅用于本地开发）
    xcrun codesign -s - "${XCFRAMEWORK_DIR}/${IOS_LIB_IDENTIFIER}/WebRTC.framework/WebRTC"

    LIB_COUNT=$((LIB_COUNT+1))
fi

# 第 5 步.2 - 添加 macOS 库到 XCFramework
if [ "$MACOS" = true ]; then

    MAC_LIB_IDENTIFIER="macos-x86_64_arm64"

    mkdir "${XCFRAMEWORK_DIR}/${MAC_LIB_IDENTIFIER}"
    plist_add_library $LIB_COUNT "${MAC_LIB_IDENTIFIER}" "macos"
    plist_add_architecture $LIB_COUNT "x86_64"
    plist_add_architecture $LIB_COUNT "arm64"

    cp -RP out/macos-x64/WebRTC.framework "${XCFRAMEWORK_DIR}/${MAC_LIB_IDENTIFIER}"
    lipo -create -output "${XCFRAMEWORK_DIR}/${MAC_LIB_IDENTIFIER}/WebRTC.framework/Versions/A/WebRTC" out/macos-x64/WebRTC.framework/WebRTC out/macos-arm64/WebRTC.framework/WebRTC
    LIB_COUNT=$((LIB_COUNT+1))
fi

# 第 5 步.3 - 添加 Catalyst 库到 XCFramework
if [ "$MAC_CATALYST" = true ]; then

    CATALYST_LIB_IDENTIFIER="ios-x86_64_arm64-maccatalyst"

    mkdir "${XCFRAMEWORK_DIR}/${CATALYST_LIB_IDENTIFIER}"
    plist_add_library $LIB_COUNT "${CATALYST_LIB_IDENTIFIER}" "ios" "maccatalyst"
    plist_add_architecture $LIB_COUNT "x86_64"
    plist_add_architecture $LIB_COUNT "arm64"

    cp -RP out/catalyst-x64/WebRTC.framework "${XCFRAMEWORK_DIR}/${CATALYST_LIB_IDENTIFIER}"
    lipo -create -output "${XCFRAMEWORK_DIR}/${CATALYST_LIB_IDENTIFIER}/WebRTC.framework/Versions/A/WebRTC" out/catalyst-x64/WebRTC.framework/WebRTC out/catalyst-arm64/WebRTC.framework/WebRTC
    LIB_COUNT=$((LIB_COUNT+1))
fi

# 第 6 步 - 将许可证文件添加到框架中
cp LICENSE ${XCFRAMEWORK_DIR}

# 第 7 步 - 打包框架
cd out
NOW=$(date -u +"%Y-%m-%dT%H-%M-%S")
OUTPUT_NAME=WebRTC-$NOW.xcframework.zip
zip --symlinks -r $OUTPUT_NAME WebRTC.xcframework/

# 第 8 步 - 计算 SHA256 校验和
CHECKSUM=$(shasum -a 256 $OUTPUT_NAME | awk '{ print $1 }')
COMMIT_HASH=$(git rev-parse HEAD)

echo "{ \"file\": \"${OUTPUT_NAME}\", \"checksum\": \"${CHECKSUM}\", \"commit\": \"${COMMIT_HASH}\", \"branch\": \"${BRANCH}\" }" > metadata.json
cat metadata.json

