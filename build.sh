#!/bin/bash

abort()
{
    popd > /dev/null 2>&1
    echo "-----------------------------------------------"
    echo "Kernel compilation failed! Exiting..."
    echo "-----------------------------------------------"
    exit 1
}

unset_flags()
{
    cat << EOF
Usage: $(basename "$0") [options]
Options:
    -m, --model [value]    Specify the model code of the phone
    -k, --ksu [y/N]        Include KernelSU
    -r, --recovery [y/N]   Compile kernel for an Android Recovery
    -d, --dtbs [y/N]	   Compile only DTBs
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model|-m)
            MODEL="$2"
            shift 2
            ;;
        --ksu|-k)
            KSU_OPTION="$2"
            shift 2
            ;;
        --recovery|-r)
            RECOVERY_OPTION="$2"
            shift 2
            ;;
        --dtbs|-d)
            DTB_OPTION="$2"
            shift 2
            ;;
        *)
            unset_flags
            exit 1
            ;;
    esac
done

echo "Preparing the build environment..."

pushd $(dirname "$0") > /dev/null
CORES=`cat /proc/cpuinfo | grep -c processor`

# Define toolchain variables
CLANG_DIR=$PWD/toolchain/clang_14
PATH=$CLANG_DIR/bin:$PATH

# Toolchain sources (clang-r450784d = Clang 14.0.6, Android 13).
# The AOSP site is unreliable, so try several sources in this order:
#   1) TOOLCHAIN_URL   - your own .tar.gz with bin/ and lib64/ at top level
#   2) TOOLCHAIN_GIT   - GitHub repo containing the clang-r450784 tree
#   3) TOOLCHAIN_LINARO - Linaro mirror of the AOSP repo (tag android-13.0.0_r13)
# Override any of them from the environment if needed.
TOOLCHAIN_URL="${TOOLCHAIN_URL:-}"
TOOLCHAIN_GIT="${TOOLCHAIN_GIT:-https://github.com/gmw-project/android_prebuilts_clang_host_linux-x86_clang-r450784}"
TOOLCHAIN_LINARO="${TOOLCHAIN_LINARO:-https://android-git.linaro.org/platform/prebuilts/clang/host/linux-x86.git}"

# Check the compiler and its runtime library. A cancelled extraction may leave
# clang-14 behind without lib64/libc++.so.1, which makes clang.real unusable.
toolchain_ok()
{
    [ -x "$CLANG_DIR/bin/clang-14" ] && [ -f "$CLANG_DIR/lib64/libc++.so.1" ]
}

reset_clang_dir()
{
    rm -rf "$CLANG_DIR"
    mkdir -p "$CLANG_DIR"
}

fetch_toolchain()
{
    local SRC
    SRC=$(mktemp -d)

    # 1) Own tarball
    if [ -n "$TOOLCHAIN_URL" ]; then
        echo "Trying TOOLCHAIN_URL..."
        reset_clang_dir
        if curl -fL "$TOOLCHAIN_URL" | tar xz -C "$CLANG_DIR" && toolchain_ok; then
            rm -rf "$SRC"
            return 0
        fi
    fi

    # 2) GitHub repo
    echo "Trying GitHub: $TOOLCHAIN_GIT"
    reset_clang_dir
    if git clone --depth 1 "$TOOLCHAIN_GIT" "$SRC/repo"; then
        rm -rf "$SRC/repo/.git"
        if [ -d "$SRC/repo/bin" ]; then
            cp -a "$SRC/repo/." "$CLANG_DIR/"
        else
            cp -a "$SRC/repo"/clang-*/. "$CLANG_DIR/" 2>/dev/null
        fi
        if toolchain_ok; then
            rm -rf "$SRC"
            return 0
        fi
        echo "GitHub repo did not contain a complete toolchain."
    fi

    # 3) Linaro mirror (sparse checkout of just clang-r450784d)
    echo "Trying Linaro mirror..."
    reset_clang_dir
    rm -rf "$SRC/repo"
    if git clone --depth 1 --filter=blob:none --sparse \
            --branch android-13.0.0_r13 "$TOOLCHAIN_LINARO" "$SRC/repo" \
        && git -C "$SRC/repo" sparse-checkout set clang-r450784d; then
        cp -a "$SRC/repo/clang-r450784d/." "$CLANG_DIR/"
        if toolchain_ok; then
            rm -rf "$SRC"
            return 0
        fi
    fi

    rm -rf "$SRC"
    return 1
}

if ! toolchain_ok; then
    echo "-----------------------------------------------"
    echo "Toolchain missing or incomplete! Downloading..."
    echo "-----------------------------------------------"
    fetch_toolchain || abort
    echo "Toolchain ready: $("$CLANG_DIR/bin/clang-14" --version | head -n1)"
fi

MAKE_ARGS="
LLVM=1 \
LLVM_IAS=1 \
ARCH=arm64 \
O=out
"

# Define specific variables
KERNEL_DEFCONFIG=extreme_"$MODEL"_defconfig
case $MODEL in
x1slte)
    BOARD=SRPSJ28B018KU
;;
x1s)
    BOARD=SRPSI19A018KU
;;
y2slte)
    BOARD=SRPSJ28A018KU
;;
y2s)
    BOARD=SRPSG12A018KU
;;
z3s)
    BOARD=SRPSI19B018KU
;;
c1slte)
    BOARD=SRPTC30B009KU
;;
c1s)
    BOARD=SRPTB27D009KU
;;
c2slte)
    BOARD=SRPTC30A009KU
;;
c2s)
    BOARD=SRPTB27C009KU
;;
r8s)
    BOARD=SRPTF26B014KU
;;
*)
    unset_flags
    exit 1
esac

if [[ "$RECOVERY_OPTION" == "y" ]]; then
    RECOVERY=recovery.config
    KSU_OPTION=n
fi

if [ -z $KSU_OPTION ]; then
    read -p "Include KernelSU (y/N): " KSU_OPTION
fi

if [[ "$KSU_OPTION" == "y" ]]; then
    KSU=ksu.config
fi

if [[ "$DTB_OPTION" == "y" ]]; then
	DTBS=y
fi

rm -rf build/out/$MODEL
mkdir -p build/out/$MODEL/zip/files
mkdir -p build/out/$MODEL/zip/META-INF/com/google/android

# Build kernel image
echo "-----------------------------------------------"
echo "Defconfig: "$KERNEL_DEFCONFIG""
if [ -z "$KSU" ]; then
    echo "KSU: N"
else
    echo "KSU: $KSU"
fi
if [ -z "$RECOVERY" ]; then
    echo "Recovery: N"
else
    echo "Recovery: Y"
fi

echo "-----------------------------------------------"
if [ -z "$DTBS" ]; then
    echo "Building kernel using "$MODEL.config""
else
    echo "Building DTBs using "$MODEL.config""
fi
echo "Generating configuration file..."
echo "-----------------------------------------------"
make ${MAKE_ARGS} -j$CORES exynos9830_defconfig $MODEL.config $KSU ksu_manual.config $RECOVERY || abort

if [ ! -z "$DTBS" ]; then
    MAKE_ARGS="$MAKE_ARGS dtbs"
    echo "Building DTBs"
else
    echo "Building kernel..."
fi

echo "-----------------------------------------------"
make ${MAKE_ARGS} -j$CORES || abort

# Define constant variables
DTB_PATH=build/out/$MODEL/dtb.img
KERNEL_PATH=build/out/$MODEL/Image
KERNEL_OFFSET=0x00008000
DTB_OFFSET=0x00000000
RAMDISK_OFFSET=0x01000000
SECOND_OFFSET=0xF0000000
TAGS_OFFSET=0x00000100
BASE=0x10000000
CMDLINE='androidboot.hardware=exynos990 loop.max_part=7'
HASHTYPE=sha1
HEADER_VERSION=2
OS_PATCH_LEVEL=2025-08
OS_VERSION=15.0.0
PAGESIZE=2048
RAMDISK=build/out/$MODEL/ramdisk.cpio.gz
OUTPUT_FILE=build/out/$MODEL/boot.img

## Build auxiliary boot.img files
# Copy kernel to build
if [ -z "$DTBS" ]; then
    cp out/arch/arm64/boot/Image build/out/$MODEL
fi

# Build dtb
echo "Building common exynos9830 Device Tree Blob Image..."
echo "-----------------------------------------------"
./toolchain/mkdtimg cfg_create build/out/$MODEL/dtb.img build/dtconfigs/exynos9830.cfg -d out/arch/arm64/boot/dts/exynos

# Build dtbo
echo "Building Device Tree Blob Output Image for "$MODEL"..."
echo "-----------------------------------------------"
./toolchain/mkdtimg cfg_create build/out/$MODEL/dtbo.img build/dtconfigs/$MODEL.cfg -d out/arch/arm64/boot/dts/samsung

if [ -z "$RECOVERY" ] && [ -z "$DTBS" ]; then
    # Build ramdisk
    echo "Building RAMDisk..."
    echo "-----------------------------------------------"
    pushd build/ramdisk > /dev/null
     find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | gzip > ../out/$MODEL/ramdisk.cpio.gz || abort
    popd > /dev/null
    echo "-----------------------------------------------"

    # Create boot image
    echo "Creating boot image..."
    echo "-----------------------------------------------"
     ./toolchain/mkbootimg --base $BASE --board $BOARD --cmdline "$CMDLINE" --dtb $DTB_PATH \
    --dtb_offset $DTB_OFFSET --hashtype $HASHTYPE --header_version $HEADER_VERSION --kernel $KERNEL_PATH \
    --kernel_offset $KERNEL_OFFSET --os_patch_level $OS_PATCH_LEVEL --os_version $OS_VERSION --pagesize $PAGESIZE \
    --ramdisk $RAMDISK --ramdisk_offset $RAMDISK_OFFSET \
    --second_offset $SECOND_OFFSET --tags_offset $TAGS_OFFSET -o $OUTPUT_FILE || abort

    # Build zip
    echo "Building zip..."
    echo "-----------------------------------------------"
    cp build/out/$MODEL/boot.img build/out/$MODEL/zip/files/boot.img
    cp build/out/$MODEL/dtbo.img build/out/$MODEL/zip/files/dtbo.img
    cp build/update-binary build/out/$MODEL/zip/META-INF/com/google/android/update-binary
    cp build/updater-script build/out/$MODEL/zip/META-INF/com/google/android/updater-script

    version=$(grep -o 'CONFIG_LOCALVERSION="[^"]*"' arch/arm64/configs/exynos9830_defconfig | cut -d '"' -f 2)
    version=${version:1}
    pushd build/out/$MODEL/zip > /dev/null
    DATE=`date +"%d-%m-%Y_%H-%M-%S"`

    if [[ "$KSU_OPTION" == "y" ]]; then
        NAME="$version"_"$MODEL"_UNOFFICIAL_KSU_"$DATE".zip
    else
        NAME="$version"_"$MODEL"_UNOFFICIAL_"$DATE".zip
    fi
    zip -r -qq ../"$NAME" .
    popd > /dev/null
fi

popd > /dev/null
echo "Build finished successfully!"
