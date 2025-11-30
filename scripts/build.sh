#!/bin/sh

## WebRTC 库构建脚本（静态库版本 - 无模拟器）
## 修改为构建静态库 XCFramework 且不包含 iOS 模拟器支持
## 原作者 Stasel，针对静态构建进行了修改
## BSD-3 许可
## https://chromiumdash.appspot.com/branches 查看版本分支
## 使用示例: MACOS=true IOS=true BUILD_VP9=true sh build.sh

# 配置项
DEBUG="${DEBUG:-false}"
BUILD_VP9="${BUILD_VP9:-false}"
BRANCH="${BRANCH:-master}"
IOS="${IOS:-false}"
MACOS="${MACOS:-false}"
MAC_CATALYST="${MAC_CATALYST:-false}"

OUTPUT_DIR="./out"
XCFRAMEWORK_DIR="out/WebRTC.xcframework"

### 静态库配置: use_custom_libcxx=false
# 静态库必须设为 false，否则集成到 App 时会报 std::string 符号冲突
# rtc_enable_protobuf=false 也是建议项，防止 protobuf 符号冲突
COMMON_GN_ARGS="is_debug=${DEBUG} rtc_libvpx_build_vp9=${BUILD_VP9} is_component_build=false rtc_include_tests=false rtc_enable_objc_symbol_export=true enable_stripping=true enable_dsyms=false use_lld=true rtc_ios_use_opengl_rendering=true use_custom_libcxx=false rtc_enable_protobuf=false"

PLISTBUDDY_EXEC="/usr/libexec/PlistBuddy"

### 函数：将编译产物打包成静态库
# 这个函数会查找 obj 目录下的所有 .o 文件，用 libtool 合并成静态库，并替换 Framework 中的动态库
make_static_binary() {
    local gen_dir=$1
    echo "正在 ${gen_dir} 中转换为静态 framework..."
    
    # 删除原本的动态库二进制文件
    rm -f "${gen_dir}/WebRTC.framework/WebRTC"
    
    # 使用 libtool 合并所有 .o 文件生成静态库
    # 我们排除了 main.o 和一些工具类的对象文件，以防止符号重复
    libtool -static -o "${gen_dir}/WebRTC.framework/WebRTC" \
        $(find "${gen_dir}/obj" -name "*.o" -type f ! -name "main.o" ! -path "*/examples/*" ! -path "*/rtc_tools/*")
        
    echo "静态二进制文件已创建于 ${gen_dir}/WebRTC.framework/WebRTC"
}

build_iOS() {
    local arch=$1
    local environment=$2
    local gen_dir="${OUTPUT_DIR}/ios-${arch}-${environment}"
    local gen_args="${COMMON_GN_ARGS} target_cpu=\"${arch}\" target_os=\"ios\" target_environment=\"${environment}\" ios_deployment_target=\"12.0\" ios_enable_code_signing=false"
    gn gen "${gen_dir}" --args="${gen_args}"
    gn args --list ${gen_dir} > ${gen_dir}/gn-args.txt
    
    # 先编译 framework_objc 以获取目录结构和头文件
    ninja -C "${gen_dir}" framework_objc || exit 1
    
    # 转换为静态库
    make_static_binary "${gen_dir}"
}

build_macOS() {
    local arch=$1
    local gen_dir="${OUTPUT_DIR}/macos-${arch}"
    local gen_args="${COMMON_GN_ARGS} target_cpu=\"${arch}\" target_os=\"mac\""
    gn gen "${gen_dir}" --args="${gen_args}"
    gn args --list ${gen_dir} > ${gen_dir}/gn-args.txt
    ninja -C "${gen_dir}" mac_framework_objc || exit 1
    
    # 转换为静态库
    make_static_binary "${gen_dir}"
}

# Catalyst 构建尚未完全正常工作。
# 参见: https://groups.google.com/g/discuss-webrtc/c/VZXS4V4mSY4
build_catalyst() {
    local arch=$1
    local gen_dir="${OUTPUT_DIR}/catalyst-${arch}"
    local gen_args="${COMMON_GN_ARGS} target_cpu=\"${arch}\" target_environment=\"catalyst\" target_os=\"ios\" ios_deployment_target=\"14.0\" ios_enable_code_signing=false"
    gn gen "${gen_dir}" --args="${gen_args}"
    gn args --list ${gen_dir} > ${gen_dir}/gn-args.txt
    ninja -C "${gen_dir}" framework_objc || exit 1
    
    # 转换为静态库
    make_static_binary "${gen_dir}"
}

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

plist_add_architecture() {
    local index=$1
    local arch=$2
    "$PLISTBUDDY_EXEC" -c "Add :AvailableLibraries:${index}:SupportedArchitectures: string ${arch}"  "${INFO_PLIST}"
}

# 第一步：下载并安装 depot tools
if [ ! -d depot_tools ]; then
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
else
    cd depot_tools
    git pull origin main
    cd ..
fi
export PATH=$(pwd)/depot_tools:$PATH

# 第二步 - 下载并构建 WebRTC
if [ ! -d src ]; then
    fetch --nohooks webrtc_ios
fi
cd src
git fetch --all
git checkout $BRANCH
cd ..
gclient sync --with_branch_heads --with_tags
cd src

# 第三步 - 编译并构建所有 framework
rm -rf $OUTPUT_DIR

if [ "$IOS" = true ]; then
    # 仅编译真机版本
    build_iOS "arm64" "device"
fi

if [ "$MACOS" = true ]; then
    build_macOS "x64"
    build_macOS "arm64"
fi

if [ "$MAC_CATALYST" = true ]; then
    build_catalyst "x64"
    build_catalyst "arm64"
fi

# 第四步 - 手动创建 XCFramework。
# 遗憾的是我们无法使用 xcodebuild `-xcodebuild -create-xcframework`，因为会报错：
# "Both ios-arm64-simulator and ios-x86_64-simulator represent two equivalent library definitions."
# 因此，我们通过 lipo 创建多架构二进制文件来手动制作 XCFramework。
# 我们还使用 plistbuddy 为 XCFramework 创建 plist 文件。

INFO_PLIST="${XCFRAMEWORK_DIR}/Info.plist"
rm -rf "${XCFRAMEWORK_DIR}"
mkdir "${XCFRAMEWORK_DIR}"
"$PLISTBUDDY_EXEC" -c "Add :CFBundlePackageType string XFWK"  "${INFO_PLIST}"
"$PLISTBUDDY_EXEC" -c "Add :XCFrameworkFormatVersion string 1.0"  "${INFO_PLIST}"
"$PLISTBUDDY_EXEC" -c "Add :AvailableLibraries array" "${INFO_PLIST}"

# 步骤 5.1 - 将 iOS 库添加到 XCFramework (仅限真机)
LIB_COUNT=0
if [[ "$IOS" = true ]]; then

    IOS_LIB_IDENTIFIER="ios-arm64"

    mkdir "${XCFRAMEWORK_DIR}/${IOS_LIB_IDENTIFIER}"
    
    # 添加 Plist 信息
    plist_add_library $LIB_COUNT $IOS_LIB_IDENTIFIER "ios"
    plist_add_architecture $LIB_COUNT "arm64"

    # 复制 Framework 目录结构
    cp -r out/ios-arm64-device/WebRTC.framework "${XCFRAMEWORK_DIR}/${IOS_LIB_IDENTIFIER}"

    # 合并二进制文件（虽然这里只有一个架构，但使用 lipo -create 是复制和标准化的好方法）
    lipo -create -output "${XCFRAMEWORK_DIR}/${IOS_LIB_IDENTIFIER}/WebRTC.framework/WebRTC" out/ios-arm64-device/WebRTC.framework/WebRTC

    LIB_COUNT=$((LIB_COUNT+1))
fi

# 步骤 5.2 - 将 macOS 库添加到 XCFramework
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

# 步骤 5.3 - 将 macOS Catalyst 库添加到 XCFramework
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

# 第六步 - 将许可证文件添加到 framework 中
cp LICENSE ${XCFRAMEWORK_DIR}

# 第七步 - 压缩归档 framework
cd out
NOW=$(date -u +"%Y-%m-%dT%H-%M-%S")
OUTPUT_NAME=WebRTC-Static-NoSim-$NOW.xcframework.zip
zip --symlinks -r $OUTPUT_NAME WebRTC.xcframework/

# 第八步 - 计算 SHA256 校验和
CHECKSUM=$(shasum -a 256 $OUTPUT_NAME | awk '{ print $1 }')
COMMIT_HASH=$(git rev-parse HEAD)

echo "{ \"file\": \"${OUTPUT_NAME}\", \"checksum\": \"${CHECKSUM}\", \"commit\": \"${COMMIT_HASH}\", \"branch\": \"${BRANCH}\", \"type\": \"static-nosim\" }" > metadata.json
cat metadata.json
