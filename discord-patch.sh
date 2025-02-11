#!/bin/bash
set -e

# Configuration
PACKAGE_NAME="app.revenge"
APP_NAME="Revenge"
DEBUG_MODE=false
MIRRORS=(
    "https://tracker.vendetta.rocks/tracker/download/"
    "https://proxy.vendetta.rocks/tracker/download/"
    "https://vd.k6.tf/tracker/download/"
    "https://discord.com/api/download/beta/android/"
    "https://dl.discordapp.net/apps/android/beta/"
)

# Enhanced download function
download_with_retry() {
    local url="$1"
    local output="$2"
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        echo "📥 Attempting download (try $((retry_count+1))/$max_retries): $url"
        if curl -f -L -v \
            -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
            -o "$output" "$url"; then
            if [ -s "$output" ] && unzip -t "$output" >/dev/null 2>&1; then
                echo "✅ Verified APK: $(ls -lh "$output")"
                return 0
            fi
            rm -f "$output"
        fi
        retry_count=$((retry_count + 1))
        sleep 2
    done
    
    echo "❌ Failed to download valid APK after $max_retries attempts"
    return 1
}

# Check arguments
if [ $# -lt 2 ]; then
    echo "❌ Usage: $0 <version_code> <module.apk> [output.apk]"
    echo "Example: $0 267108 module.apk discord-revenge.apk"
    exit 1
fi

# Parse arguments
VERSION="$1"
MODULE_APK="$2"
OUTPUT_APK="${3:-discord-revenge-${VERSION}.apk}"
[[ "$OUTPUT_APK" != *.apk ]] && OUTPUT_APK="${OUTPUT_APK%.*}.apk"

# Verify inputs
[ -f "$MODULE_APK" ] || { echo "❌ Module APK not found: $MODULE_APK"; exit 1; }
[ -f "lspatch.jar" ] || { echo "❌ lspatch.jar missing!"; exit 1; }
[ -f "APKEditor.jar" ] || { echo "❌ APKEditor.jar missing!"; exit 1; }

# Check dependencies
check_dependency() {
    if ! command -v "$1" &>/dev/null; then
        echo "❌ Missing required tool: $1"
        exit 1
    fi
}

check_dependency java
check_dependency curl
check_dependency aapt2
check_dependency zipalign
check_dependency apksigner
check_dependency apktool

# Architecture setup
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|aarch64) DISCORD_ARCH="arm64_v8a" ;;
    armv7l) DISCORD_ARCH="armeabi_v7a" ;;
    *) echo "❌ Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Setup workspace
WORK_DIR=$(mktemp -d)
DOWNLOAD_DIR="$WORK_DIR/downloads"
MERGED_DIR="$WORK_DIR/merged"
PATCHED_DIR="$WORK_DIR/patched"
SIGNED_DIR="$WORK_DIR/signed"
mkdir -p "$DOWNLOAD_DIR" "$MERGED_DIR" "$PATCHED_DIR" "$SIGNED_DIR"

# Cleanup handler
cleanup() {
    if [ $? -eq 0 ]; then
        echo "🧹 Cleaning temporary files..."
        rm -rf "$WORK_DIR"
    else
        echo "🛑 Error preserved workdir: $WORK_DIR"
    fi
}
trap cleanup EXIT

# Align resources.arsc for API 30+
align_resources() {
    local apk_file="$1"
    local temp_dir=$(mktemp -d)
    
    echo "📐 Aligning resources in $(basename "$apk_file")"
    
    # Extract resources.arsc
    if unzip -p "$apk_file" "resources.arsc" > "$temp_dir/resources.arsc"; then
        # Create new zip without resources.arsc
        cd "$temp_dir"
        unzip "$apk_file" -x "resources.arsc" >/dev/null
        
        # Add aligned resources.arsc back
        zip -0 "$apk_file" "resources.arsc" >/dev/null
        
        echo "✅ Resources aligned"
        rm -rf "$temp_dir"
        return 0
    else
        echo "⚠️ No resources.arsc found"
        rm -rf "$temp_dir"
        return 0
    fi
}

# Sign APK before LSPatch
presign_apk() {
    local input_apk="$1"
    local output_apk="$2"
    
    echo "📝 Signing APK: $(basename "$input_apk")"
    
    # First copy the input APK
    cp "$input_apk" "$output_apk" || {
        echo "❌ Failed to copy APK"
        return 1
    }
    
    # Then sign in place
    apksigner sign --ks "revenge.keystore" \
        --ks-key-alias alias \
        --ks-pass pass:password \
        --key-pass pass:password \
        --v2-signing-enabled true \
        --v3-signing-enabled true \
        "$output_apk" || {
        echo "❌ Failed to sign APK"
        rm -f "$output_apk"
        return 1
    }
    
    echo "✅ Successfully signed APK"
}

# Patch with LSPatch
patch_apk() {
    local input="$1" output_dir="$2"
    echo "🔨 Patching $(basename "$input")..."
    
    # Convert paths to absolute paths as required by LSPatch
    local abs_input="$(cd "$(dirname "$input")" &> /dev/null && pwd)/$(basename "$input")"
    local abs_module="$(cd "$(dirname "$MODULE_APK")" &> /dev/null && pwd)/$(basename "$MODULE_APK")"
    
    java -jar lspatch.jar \
        -m "$abs_module" \
        -o "$output_dir" \
        -l 0 \
        -v \
        -f \
        "$abs_input" \
        -k "revenge.keystore" \
        "password" \
        "alias" \
        "password" >/dev/null 2>&1 || {
            echo "❌ Patching failed for $(basename "$input")"
            return 1
        }
    
    # Rename patched APK
    local patched_file=$(find "$output_dir" -name "*-lspatched.apk" | head -n 1)
    if [ -n "$patched_file" ]; then
        mv -v "$patched_file" "$output_dir/patched.apk"
    else
        echo "❌ Failed to locate patched file"
        return 1
    fi
}

# Download APKs
echo "🌐 Downloading Discord v$VERSION APKs..."

# Base APK
success=false
for mirror in "${MIRRORS[@]}"; do
    if [[ "$mirror" == *"tracker"* ]]; then
        url="${mirror}${VERSION}/base"
    else
        url="${mirror}base-${VERSION}.apk"
    fi
    
    if download_with_retry "$url" "$DOWNLOAD_DIR/base.apk"; then
        success=true
        break
    fi
done
$success || { echo "❌ Failed to download base APK"; exit 1; }

# Split APKs
SPLIT_TYPES=("config.${DISCORD_ARCH}" "config.en" "config.xxhdpi")
for type in "${SPLIT_TYPES[@]}"; do
    success=false
    for mirror in "${MIRRORS[@]}"; do
        if [[ "$mirror" == *"tracker"* ]]; then
            url="${mirror}${VERSION}/${type}"
        else
            url="${mirror}${type}-${VERSION}.apk"
        fi
        
        if download_with_retry "$url" "$DOWNLOAD_DIR/${type}.apk"; then
            success=true
            break
        fi
    done
    $success || echo "⚠️ Failed to download split: $type"
done

# Merge APKs before patching
echo "🔄 Merging original APKs..."
MERGED_APK="$MERGED_DIR/merged.apk"
java -jar APKEditor.jar m \
    -i "$DOWNLOAD_DIR" \
    -o "$MERGED_APK" || {
        echo "❌ Failed to merge APKs"
        exit 1
    }

# Verify merged APK
if [ ! -f "$MERGED_APK" ] || ! unzip -t "$MERGED_APK" >/dev/null 2>&1; then
    echo "❌ Merged APK is invalid"
    exit 1
fi

# After merging APKs
echo "🔄 Processing merged APK..."
PRESIGNED_APK="$SIGNED_DIR/presigned.apk"

# Align resources first
align_resources "$MERGED_APK"

# Sign before LSPatch
presign_apk "$MERGED_APK" "$PRESIGNED_APK" || exit 1

# Patch with LSPatch
echo "⚙️ Starting patching process..."
patch_apk "$PRESIGNED_APK" "$PATCHED_DIR" || exit 1

# Finalize output
mv "$PATCHED_DIR/patched.apk" "$OUTPUT_APK"

echo -e "\n✅ Successfully built patched Discord!"
echo "📦 Output file: $(realpath "$OUTPUT_APK")"

# Add before final echo statements
echo "🔍 Verifying patched APK..."
if ! unzip -t "$OUTPUT_APK" >/dev/null 2>&1; then
    echo "❌ Output APK verification failed"
    exit 1
fi

# Verify package name
if ! aapt2 dump badging "$OUTPUT_APK" | grep -q "package: name='$PACKAGE_NAME'"; then
    echo "❌ Package name verification failed"
    exit 1
fi

echo "✅ APK verification passed"
