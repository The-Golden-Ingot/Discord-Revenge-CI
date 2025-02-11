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

# Patch with LSPatch
patch_apk() {
    local input_apk="$1"
    local output_dir="$2"
    
    echo "🔨 Patching $(basename "$input_apk")..."
    
    # Store LSPatch output
    local lspatch_log="$WORK_DIR/lspatch.log"
    
    # Run LSPatch with full error output
    java -jar lspatch.jar \
        "$input_apk" \
        --module "$MODULE_APK" \
        --name "$APP_NAME" > "$lspatch_log" 2>&1 || {
        echo "❌ LSPatch failed with error:"
        cat "$lspatch_log"
        return 1
    }
    
    # Find output more reliably
    local patched_file=$(grep -oP 'Output: \K.*' "$lspatch_log" || true)
    
    [ -f "$patched_file" ] || {
        echo "❌ LSPatch failed to produce output APK. Full log:"
        cat "$lspatch_log"
        return 1
    }
    
    echo "🔄 Finalizing patched APK..."
    mkdir -p "$output_dir"
    mv "$patched_file" "$output_dir/patched.apk"
    
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

# Patch with LSPatch
echo "⚙️ Starting patching process..."
patch_apk "$PRESIGNED_APK" "$PATCHED_DIR" || exit 1

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

# Update the APKEditor download section
echo "📥 Downloading APKEditor..."
APKEDITOR_URL="https://github.com/REAndroid/APKEditor/releases/download/v1.4.2/APKEditor-1.4.2.jar"
curl -L -o APKEditor.jar "$APKEDITOR_URL" || {
    echo "❌ Failed to download APKEditor"
    exit 1
}

# Verify the download
if [ ! -f "APKEditor.jar" ] || [ ! -s "APKEditor.jar" ]; then
    echo "❌ Downloaded APKEditor.jar is invalid"
    exit 1
fi

# Verify it's a valid jar file
if ! jar tf APKEditor.jar >/dev/null 2>&1; then
    echo "❌ APKEditor.jar is corrupted"
    exit 1
fi

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