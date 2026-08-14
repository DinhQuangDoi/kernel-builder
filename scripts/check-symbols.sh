#!/bin/bash
# check-symbols.sh - Compile check_symbol.c and verify symbols between ksud.ko and vmlinux
# Version: 1.0.0

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="${SCRIPT_DIR}/../tools"
VERBOSE=false

# Functions
print_header() {
    echo -e "${BOLD}${BLUE}========================================${NC}"
    echo -e "${BOLD}${BLUE}  KSU Symbol Verification${NC}"
    echo -e "${BOLD}${BLUE}========================================${NC}"
    echo ""
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

download_check_symbol() {
    if [ ! -f "${TOOLS_DIR}/check_symbol.c" ]; then
        print_info "Downloading check_symbol.c from ReSukiSU..."
        
        mkdir -p "${TOOLS_DIR}"
        curl -sL "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/tools/check_symbol.c" \
            -o "${TOOLS_DIR}/check_symbol.c" 2>/dev/null || {
            print_error "Failed to download check_symbol.c"
            return 1
        }
    fi
    return 0
}

compile_check_symbol() {
    print_info "Compiling check_symbol..."
    
    local src="${TOOLS_DIR}/check_symbol.c"
    local out="${TOOLS_DIR}/check_symbol"
    
    if ! command -v gcc &>/dev/null; then
        print_error "gcc not found. Cannot compile check_symbol.c"
        return 1
    fi
    
    gcc -o "$out" "$src" 2>/dev/null || {
        print_error "Failed to compile check_symbol.c"
        return 1
    }
    
    print_success "Compiled check_symbol successfully"
    return 0
}

find_ksud_ko() {
    local ksud_path=""
    
    # Common locations
    local possible_paths=(
        "drivers/kernelsu/ksud.ko"
        "ksud.ko"
        "out/drivers/kernelsu/ksud.ko"
        "build/ksud.ko"
    )
    
    for path in "${possible_paths[@]}"; do
        if [ -f "$path" ]; then
            ksud_path="$path"
            break
        fi
    done
    
    echo "$ksud_path"
}

find_vmlinux() {
    local vmlinux_path=""
    
    # Common locations
    local possible_paths=(
        "vmlinux"
        "arch/arm64/boot/vmlinux"
        "arch/arm/boot/vmlinux"
        "out/vmlinux"
        "build/vmlinux"
    )
    
    for path in "${possible_paths[@]}"; do
        if [ -f "$path" ]; then
            vmlinux_path="$path"
            break
        fi
    done
    
    echo "$vmlinux_path"
}

run_symbol_check() {
    local ksud="$1"
    local vmlinux="$2"
    
    print_info "Running symbol check..."
    print_info "  ksud.ko: $ksud"
    print_info "  vmlinux: $vmlinux"
    echo ""
    
    "${TOOLS_DIR}/check_symbol" "$ksud" "$vmlinux"
    local result=$?
    
    echo ""
    
    if [ $result -eq 0 ]; then
        print_success "Symbol check PASSED"
        return 0
    else
        print_error "Symbol check FAILED"
        print_info "This may indicate kernel version mismatch or missing exports"
        return 1
    fi
}

show_help() {
    echo "Usage: $0 [ksud.ko] [vmlinux]"
    echo ""
    echo "If no arguments provided, will search for files in common locations."
    echo ""
    echo "Example:"
    echo "  $0 drivers/kernelsu/ksud.ko vmlinux"
    echo ""
}

main() {
    print_header
    
    local ksud="${1:-}"
    local vmlinux="${2:-}"
    
    # Download and compile check_symbol if needed
    download_check_symbol || exit 1
    compile_check_symbol || exit 1
    
    # Find files if not provided
    if [ -z "$ksud" ]; then
        ksud=$(find_ksud_ko)
        if [ -z "$ksud" ]; then
            print_error "ksud.ko not found"
            print_info "Build the kernel first or provide path as argument"
            show_help
            exit 1
        fi
        print_info "Found ksud.ko: $ksud"
    fi
    
    if [ -z "$vmlinux" ]; then
        vmlinux=$(find_vmlinux)
        if [ -z "$vmlinux" ]; then
            print_error "vmlinux not found"
            print_info "Build the kernel first or provide path as argument"
            show_help
            exit 1
        fi
        print_info "Found vmlinux: $vmlinux"
    fi
    
    # Verify files exist
    if [ ! -f "$ksud" ]; then
        print_error "ksud.ko not found: $ksud"
        exit 1
    fi
    
    if [ ! -f "$vmlinux" ]; then
        print_error "vmlinux not found: $vmlinux"
        exit 1
    fi
    
    # Run check
    run_symbol_check "$ksud" "$vmlinux"
    exit $?
}

main "$@"
