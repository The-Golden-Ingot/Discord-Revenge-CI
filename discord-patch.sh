#!/bin/bash
set -e

# Configuration
PACKAGE_NAME="com.discord"
APP_NAME="Revenge"
DEBUG_MODE=false
MIRRORS=(
    "https://tracker.vendetta.rocks/tracker/download/"
    "https://proxy.vendetta.rocks/tracker/download/"
    "https://vd.k6.tf/tracker/download/"
    "https://discord.com/api/download/stable/android/"
    "https://dl.discordapp.net/apps/android/stable/"
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

# Add after dependency checks, before workspace setup
# Generate keystore if missing
echo "🔑 Checking keystore..."
if [ ! -f "revenge.keystore" ]; then
    echo "📝 Generating new keystore..."
    keytool -genkey -v \
        -keystore revenge.keystore \
        -alias alias \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -storepass password \
        -keypass password \
        -dname "CN=Revenge Manager" || {
        echo "❌ Failed to generate keystore"
        exit 1
    }
fi

# Verify keystore exists and is valid
if ! keytool -list -keystore revenge.keystore -storepass password >/dev/null 2>&1; then
    echo "❌ Invalid keystore file"
    exit 1
fi

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

# Update the resource injection and alignment logic
handle_resources_alignment() {
    local apk_file="$1"
    local temp_dir=$(mktemp -d)
    
    echo "📐 Processing resources.arsc in $(basename "$apk_file")..."
    
    # First try merged APK, then base APK
    if ! unzip -j "$apk_file" "resources.arsc" -d "$temp_dir" >/dev/null 2>&1; then
        echo "⚠️ resources.arsc missing in merged APK - injecting from base"
        if ! unzip -j "$DOWNLOAD_DIR/base.apk" "resources.arsc" -d "$temp_dir" >/dev/null 2>&1; then
            echo "❌ Failed to extract resources.arsc from base APK"
            return 1
        fi
        # Add with compression level 0
        zip -q -0 -X "$apk_file" "$temp_dir/resources.arsc"
    fi
    
    # Always attempt alignment with zipalign
    echo "⚙️ Realigning resources with zipalign..."
    if ! zipalign -c 4 "$apk_file"; then
        echo "🔄 Realigning APK resources..."
        local aligned_apk="${apk_file%.apk}-aligned.apk"
        zipalign -p -f 4 "$apk_file" "$aligned_apk" || return 1
        mv "$aligned_apk" "$apk_file"
    fi
    
    # Verify alignment
    if ! zipalign -c 4 "$apk_file"; then
        echo "❌ Failed to align resources.arsc"
        return 1
    fi
    
    echo "✅ Resources successfully aligned"
    return 0
}

# Sign APK before LSPatch
presign_apk() {
    local input_apk="$1"
    local output_apk="$2"
    local abs_input="$(cd "$(dirname "$input_apk")" &> /dev/null && pwd)/$(basename "$input_apk")"
    local abs_output="$(cd "$(dirname "$output_apk")" &> /dev/null && pwd)/$(basename "$output_apk")"
    local abs_keystore="$(pwd)/revenge.keystore"
    
    echo "📝 Signing APK: $(basename "$input_apk")"
    
    # First copy the input APK
    cp "$abs_input" "$abs_output" || {
        echo "❌ Failed to copy APK"
        return 1
    }
    
    # Then sign in place
    apksigner sign --ks "$abs_keystore" \
        --ks-key-alias alias \
        --ks-pass pass:password \
        --key-pass pass:password \
        --v2-signing-enabled true \
        --v3-signing-enabled true \
        "$abs_output" || {
        echo "❌ Failed to sign APK"
        rm -f "$abs_output"
        return 1
    }
    
    echo "✅ Successfully signed APK"
}

# Update the patch_apk function to use correct LSPatch arguments
patch_apk() {
    local input_apk="$1"
    local output_dir="$2"
    local module_apk="$3"
    
    echo "🔨 Patching $(basename "$input_apk")..."
    
    # Create clean output directory
    local lspatch_out="$output_dir/lspatch_temp"
    mkdir -p "$lspatch_out"
    
    # Ensure absolute paths and verify files
    local abs_input=$(realpath "$input_apk")
    local abs_module=$(realpath "$module_apk")
    
    echo "📦 Using input APK: $abs_input"
    echo "📦 Using module APK: $abs_module"
    
    # Run LSPatch with correct argument order and format
    if ! java -jar lspatch.jar \
        "$abs_input" \
        -m "$abs_module" \
        -o "$lspatch_out" \
        -f \
        -v; then
        echo "❌ LSPatch failed to produce output APK"
        return 1
    fi
    
    # Find and move the actual output file
    local output_apk=$(find "$lspatch_out" -name '*-lspatched.apk' | head -1)
    if [ -f "$output_apk" ]; then
        mv "$output_apk" "$output_dir/patched.apk"
        rm -rf "$lspatch_out"
    else
        echo "❌ Could not find LSPatch output file"
        echo "📂 Contents of temp dir:"
        ls -lR "$lspatch_out"
        return 1
    fi
    
    return 0
}

# Add this function after download_with_retry
align_apk_resources() {
    local apk_file="$1"
    echo "📐 Aligning resources.arsc in $(basename "$apk_file")..."
    
    # Extract resources.arsc if it exists
    local temp_dir=$(mktemp -d)
    if unzip -j "$apk_file" "resources.arsc" -d "$temp_dir" >/dev/null 2>&1; then
        # Remove and re-add with proper alignment
        zip -q --delete "$apk_file" "resources.arsc" || true
        zip -q -0 -X "$apk_file" "$temp_dir/resources.arsc"
        rm -rf "$temp_dir"
        return 0
    fi
    rm -rf "$temp_dir"
    return 0
}

# Download required tools
download_apkeditor() {
    echo "📥 Downloading APKEditor..."
    local DOWNLOAD_URL=$(curl -s https://api.github.com/repos/REAndroid/APKEditor/releases/latest | \
        grep "browser_download_url.*jar" | \
        cut -d '"' -f 4)
    
    if [ -z "$DOWNLOAD_URL" ]; then
        echo "❌ Could not find APKEditor download URL"
        return 1
    fi
    
    echo "📥 Downloading from: $DOWNLOAD_URL"
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        echo "📥 Attempting download (try $((retry_count+1))/$max_retries)"
        if curl -L -o APKEditor.jar "$DOWNLOAD_URL" && \
           [ -s "APKEditor.jar" ] && \
           jar tf APKEditor.jar >/dev/null 2>&1; then
            echo "✅ Successfully downloaded APKEditor"
            return 0
        fi
        rm -f APKEditor.jar
        retry_count=$((retry_count + 1))
        sleep 2
    done
    
    echo "❌ Failed to download valid APKEditor.jar after $max_retries attempts"
    return 1
}

# Download required tools before processing
echo "📥 Downloading required tools..."
if [ ! -f "APKEditor.jar" ]; then
    if ! download_apkeditor; then
        exit 1
    fi
fi

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

# Update the APK processing section (around line 350)
echo "🔄 Processing downloaded APKs..."
for apk in "$DOWNLOAD_DIR"/*.apk; do
    [ -f "$apk" ] || continue
    echo "📐 Processing $(basename "$apk")..."
    
    # Full resource alignment using handle_resources_alignment
    if ! handle_resources_alignment "$apk"; then
        echo "❌ Resource alignment failed for $(basename "$apk")"
        exit 1
    fi
done

# Update the APK merging section
echo "🔄 Merging aligned APKs..."
MERGED_APK="$MERGED_DIR/merged.apk"
echo "⚙️ Using APKEditor to merge splits..."
java -jar APKEditor.jar m \
    -i "$DOWNLOAD_DIR" \
    -o "$MERGED_APK" || {
        echo "❌ Failed to merge APKs"
        exit 1
    }

# Add package name verification after merging
echo "🔍 Verifying merged package name..."
MERGED_PKG=$(aapt2 dump badging "$MERGED_APK" | grep "package: name")
if [[ "$MERGED_PKG" != *"$PACKAGE_NAME"* ]]; then
    echo "❌ Merge failed to set package name:"
    echo "$MERGED_PKG"
    exit 1
fi

# After merging APKs
echo "🔄 Processing merged APK..."
PRESIGNED_APK="$SIGNED_DIR/presigned.apk"

# Sign before LSPatch
presign_apk "$MERGED_APK" "$PRESIGNED_APK" || exit 1

# Update the patch invocation (around line 318)
if [ ! -f "$MODULE_APK" ]; then
    echo "❌ Module APK not found: $MODULE_APK"
    exit 1
fi

echo "⚙️ Starting patching process..."
if ! patch_apk "$PRESIGNED_APK" "$PATCHED_DIR" "$MODULE_APK"; then
    echo "🛑 Error preserved workdir: $WORK_DIR"
    exit 1
fi

# Finalize output
mv "$PATCHED_DIR/patched.apk" "$OUTPUT_APK"

echo -e "\n✅ Successfully built patched Discord!"
echo "📦 Output file: $(realpath "$OUTPUT_APK")"

# Add before final verification
echo "🔍 Checking APK identification metadata..."
APK_BADGING=$(aapt2 dump badging "$OUTPUT_APK" 2>/dev/null || true)

if [ -z "$APK_BADGING" ]; then
    echo "❌ Failed to read APK identification data"
    exit 1
fi

echo "📦 APK Identification Data:"
echo "$APK_BADGING" | grep -E "package:|versionCode=|versionName="

if ! echo "$APK_BADGING" | grep -q "versionCode="; then
    echo "❌ Missing versionCode in APK"
    exit 1
fi

if ! echo "$APK_BADGING" | grep -q "versionName="; then
    echo "❌ Missing versionName in APK"
    exit 1
fi

# Update the final verification steps
# Replace the verification section with:
echo "🔍 Verifying final APK..."

# Check if file exists and is not empty
if [ ! -f "$OUTPUT_APK" ]; then
    echo "❌ Output APK does not exist"
    exit 1
fi

if [ ! -s "$OUTPUT_APK" ]; then
    echo "❌ Output APK is empty"
    exit 1
fi

# Detailed zip verification
if ! unzip -l "$OUTPUT_APK" >/dev/null 2>&1; then
    echo "❌ Output APK is not a valid zip file"
    exit 1
fi

# Try to read the manifest
if ! unzip -p "$OUTPUT_APK" "AndroidManifest.xml" >/dev/null 2>&1; then
    echo "❌ Cannot read AndroidManifest.xml from APK"
    exit 1
fi

# Verify package name with more detailed output
echo "📦 Verifying package name..."
PACKAGE_INFO=$(aapt2 dump badging "$OUTPUT_APK" 2>/dev/null || true)
if [ -z "$PACKAGE_INFO" ]; then
    echo "❌ Failed to read package info"
    exit 1
fi

if ! echo "$PACKAGE_INFO" | grep -q "package: name='com.discord'"; then
    echo "❌ Package name verification failed"
    echo "Expected: com.discord"
    echo "Found: $(echo "$PACKAGE_INFO" | grep "package: name" || echo "none")"
    exit 1
fi

# Verify APK signature
echo "🔐 Verifying APK signature..."
if ! apksigner verify --verbose "$OUTPUT_APK"; then
    echo "❌ APK signature verification failed"
    exit 1
fi

echo "✅ All verifications passed"

# Update the merge verification (replace lines 297-304)
echo "🔍 Verifying merged APK structure..."
if ! unzip -l "$MERGED_APK" | grep -q "resources.arsc"; then
    echo "⚠️ resources.arsc missing in merged APK - injecting from base"
    unzip -j "$DOWNLOAD_DIR/base.apk" "resources.arsc" -d "$MERGED_DIR"
    zip -q -0 -X "$MERGED_APK" "$MERGED_DIR/resources.arsc"
    rm -f "$MERGED_DIR/resources.arsc"
    
    # Re-align merged APK
    if ! handle_resources_alignment "$MERGED_APK"; then
        echo "❌ Failed to align merged APK resources"
        exit 1
    fi
fi
