#!/bin/bash
# detect-toolchain.sh - Auto detect toolchain (Clang/GCC) from kernel source
# Version: 1.0.0

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\�[0m' # No Color
BOLD='\033[1m'

# Output
OUTPUT_JSON=false
VERBOSE=false

# Functions
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -j, --json     Output in JSON format"
    echo "  -v, --verbose  Verbose output"
    echo "  -h, --help     Show this help"
    echo ""
    exit 0
}

print_info() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

print_result() {
    if [ "$OUTPUT_JSON" = true ]; then
        echo "$1"
    else
        echo "$1"
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -j|--json)
            OUTPUT_JSON=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

detect_clang() {
    local clang_path=""
    local clang_version=""
    local clang_found=false
    
    # Check CC= in Makefile
    if grep -q "^CC\s*.*clang" Makefile 2>/dev/null; then
        clang_path=$(grep "^CC\s*.*clang" Makefile | head -1 | awk '{print $NF}')
        clang_found=true
        print_info "Found CC=clang in Makefile: $clang_path"
    fi
    
    # Check CLANG_TRIPLE
    if grep -q "CLANG_TRIPLE" Makefile 2>/dev/null; then
        clang_triple=$(grep "CLANG_TRIPLE" Makefile | head -1 | cut -d'=' -f2)
        clang_found=true
        print_info "Found CLANG_TRIPLE: $clang_triple"
    fi
    
    # Check for .clang files
    if [ -f ".clang" ]; then
        clang_path=$(cat .clang 2>/dev/null)
        clang_found=true
        print_info "Found .clang file: $clang_path"
    fi
    
    # Check common clang locations
    local common_clangs=(
        "/usr/bin/clang"
        "/usr/bin/clang-17"
        "/usr/bin/clang-16"
        "/usr/bin/clang-15"
        "/usr/bin/clang-14"
        "/usr/bin/clang-13"
        "/usr/bin/clang-12"
    )
    
    for clang_bin in "${common_clangs[@]}"; do
        if command -v "$clang_bin" &>/dev/null; then
            clang_path="$clang_bin"
            clang_found=true
            clang_version=$("$clang_bin" --version 2>/dev/null | head -1)
            print_info "Found system clang: $clang_bin"
            break
        fi
    done
    
    # Try to get clang version
    if [ -n "$clang_path" ] && command -v "$clang_path" &>/dev/null; then
        clang_version=$("$clang_path" --version 2>/dev/null | head -1)
    elif command -v clang &>/dev/null; then
        clang_version=$(clang --version 2>/dev/null | head -1)
    fi
    
    if [ "$clang_found" = true ]; then
        echo "clang"
    else
        echo "none"
    fi
}

detect_gcc() {
    local gcc_path=""
    local gcc_version=""
    local gcc_found=false
    
    # Check CROSS_COMPILE in Makefile
    if grep -q "CROSS_COMPILE" Makefile 2>/dev/null; then
        cross_compile=$(grep "CROSS_COMPILE" Makefile | head -1 | cut -d'=' -f2)
        gcc_found=true
        print_info "Found CROSS_COMPILE: $cross_compile"
    fi
    
    # Check for GCC in common locations
    local common_gccs=(
        "aarch64-linux-gnu-gcc"
        "arm-eabi-gcc"
        "arm-linux-gnueabi-gcc"
        "arm-none-eabi-gcc"
    )
    
    for gcc_bin in "${common_gccs[@]}"; do
        if command -v "$gcc_bin" &>/dev/null; then
            gcc_path="$gcc_bin"
            gcc_found=true
            gcc_version=$("$gcc_bin" --version 2>/dev/null | head -1)
            print_info "Found system gcc: $gcc_bin"
            break
        fi
    done
    
    if [ "$gcc_found" = true ]; then
        echo "gcc"
    else
        echo "none"
    fi
}

detect_llvm() {
    # Check for LLVM utilities
    local llvm_utils=(
        "llvm-strip"
        "llvm-objcopy"
        "llvm-objdump"
        "llvm-readelf"
    )
    
    for util in "${llvm_utils[@]}"; do
        if command -v "$util" &>/dev/null; then
            print_info "Found LLVM utility: $util"
            return 0
        fi
    done
    
    return 1
}

get_toolchain_info() {
    local type="$1"
    
    if [ "$type" = "clang" ]; then
        local clang_bin=""
        
        # Find clang binary
        if grep -q "^CC\s*.*clang" Makefile 2>/dev/null; then
            clang_bin=$(grep "^CC\s*.*clang" Makefile | head -1 | awk '{print $NF}')
        elif command -v clang &>/dev/null; then
            clang_bin="clang"
        fi
        
        if [ -n "$clang_bin" ] && command -v "$clang_bin" &>/dev/null; then
            local version=$("$clang_bin" --version 2>/dev/null | head -1)
            echo "$clang_bin|$version"
        else
            echo "clang|unknown"
        fi
    elif [ "$type" = "gcc" ]; then
        local gcc_bin=""
        
        # Find gcc binary
        if grep -q "CROSS_COMPILE" Makefile 2>/dev/null; then
            local prefix=$(grep "CROSS_COMPILE" Makefile | head -1 | cut -d'=' -f2)
            if command -v "${prefix}gcc" &>/dev/null; then
                gcc_bin="${prefix}gcc"
            fi
        fi
        
        if [ -z "$gcc_bin" ]; then
            for gcc_name in aarch64-linux-gnu-gcc arm-eabi-gcc arm-linux-gnueabi-gcc; do
                if command -v "$gcc_name" &>/dev/null; then
                    gcc_bin="$gcc_name"
                    break
                fi
            done
        fi
        
        if [ -n "$gcc_bin" ] && command -v "$gcc_bin" &>/dev/null; then
            local version=$("$gcc_bin" --version 2>/dev/null | head -1)
            echo "$gcc_bin|$version"
        else
            echo "gcc|unknown"
        fi
    else
        echo "none|unknown"
    fi
}

main() {
    local clang_type=$(detect_clang)
    local gcc_type=$(detect_gcc)
    local has_llvm=$(detect_llvm && echo "yes" || echo "no")
    
    local final_type="unknown"
    local toolchain_bin="unknown"
    local toolchain_version="unknown"
    
    # Determine primary toolchain
    if [ "$clang_type" != "none" ]; then
        final_type="clang"
        local info=$(get_toolchain_info "clang")
        toolchain_bin=$(echo "$info" | cut -d'|' -f1)
        toolchain_version=$(echo "$info" | cut -d'|' -f2)
    elif [ "$gcc_type" != "none" ]; then
        final_type="gcc"
        local info=$(get_toolchain_info "gcc")
        toolchain_bin=$(echo "$info" | cut -d'|' -f1)
        toolchain_version=$(echo "$info" | cut -d'|' -f2)
    fi
    
    # Output
    if [ "$OUTPUT_JSON" = true ]; then
        cat <<EOF
{
  "toolchain_type": "$final_type",
  "toolchain_binary": "$toolchain_bin",
  "toolchain_version": "$toolchain_version",
  "has_llvm_utils": $has_llvm,
  "clang_detected": $([ "$clang_type" != "none" ] && echo "true" || echo "false"),
  "gcc_detected": $([ "$gcc_type" != "none" ] && echo "true" || echo "false")
}
EOF
    else
        echo "========================================"
        echo "  Toolchain Detection Results"
        echo "========================================"
        echo ""
        echo "Primary Toolchain: $final_type"
        echo "Binary: $toolchain_bin"
        echo "Version: $toolchain_version"
        echo "LLVM Utils: $has_llvm"
        echo ""
        echo "Clang Detected: $([ "$clang_type" != "none" ] && echo 'Yes' || echo 'No')"
        echo "GCC Detected: $([ "$gcc_type" != "none" ] && echo 'Yes' || echo 'No')"
        echo ""
    fi
}

main "$@"
