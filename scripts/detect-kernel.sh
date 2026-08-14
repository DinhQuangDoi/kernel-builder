#!/bin/bash
# detect-kernel.sh - Extract kernel version from Makefile
# Version: 1.0.0

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
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

get_kernel_version() {
    local version=""
    local patchlevel=""
    local sublevel=""
    local extraversion=""
    local name=""
    
    if [ -f "Makefile" ]; then
        version=$(grep "^VERSION\s*=" Makefile | head -1 | awk -F'=' '{print $2}' | tr -d ' ')
        patchlevel=$(grep "^PATCHLEVEL\s*=" Makefile | head -1 | awk -F'=' '{print $2}' | tr -d ' ')
        sublevel=$(grep "^SUBLEVEL\s*=" Makefile | head -1 | awk -F'=' '{print $2}' | tr -d ' ')
        extraversion=$(grep "^EXTRAVERSION\s*=" Makefile | head -1 | awk -F'=' '{print $2}' | tr -d ' ')
        name=$(grep "^NAME\s*=" Makefile | head -1 | awk -F'=' '{print $2}' | tr -d ' ')
    fi
    
    # Handle empty values
    version=${version:-0}
    patchlevel=${patchlevel:-0}
    sublevel=${sublevel:-0}
    extraversion=${extraversion:-}
    name=${name:-}
    
    echo "$version|$patchlevel|$sublevel|$extraversion|$name"
}

get_full_version() {
    local version="$1"
    local patchlevel="$2"
    local sublevel="$3"
    local extraversion="$4"
    
    local full_version="${version}.${patchlevel}"
    
    if [ -n "$sublevel" ] && [ "$sublevel" != "0" ]; then
        full_version="${full_version}.${sublevel}"
    fi
    
    if [ -n "$extraversion" ]; then
        full_version="${full_version}${extraversion}"
    fi
    
    echo "$full_version"
}

get_kernel_family() {
    local major="$1"
    local minor="$2"
    
    # Common families
    if [ "$major" = "4" ]; then
        if [ "$minor" -ge 19 ]; then
            echo "4.19+"
        elif [ "$minor" -ge 14 ]; then
            echo "4.14+"
        elif [ "$minor" -ge 9 ]; then
            echo "4.9+"
        else
            echo "4.x"
        fi
    elif [ "$major" = "5" ]; then
        echo "5.x"
    elif [ "$major" = "6" ]; then
        echo "6.x"
    else
        echo "unknown"
    fi
}

get_arch() {
    local arch=""
    
    # Check Makefile
    if grep -q "^ARCH\s*=" Makefile 2>/dev/null; then
        arch=$(grep "^ARCH\s*=" Makefile | head -1 | awk -F'=' '{print $2}' | tr -d ' ')
    fi
    
    # Check environment
    if [ -z "$arch" ] && [ -n "$ARCH" ]; then
        arch="$ARCH"
    fi
    
    # Default
    arch=${arch:-arm64}
    
    echo "$arch"
}

get_defconfig() {
    local defconfig=""
    
    # Common locations
    local possible_defconfigs=(
        "arch/arm64/configs/*_defconfig"
        "arch/arm/configs/*_defconfig"
        "arch/x86/configs/*_defconfig"
        "arch/arm64/configs/vendor/*_defconfig"
        "arch/arm/configs/vendor/*_defconfig"
    )
    
    for pattern in "${possible_defconfigs[@]}"; do
        local found=$(ls $pattern 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            defconfig="$found"
            break
        fi
    done
    
    echo "$defconfig"
}

check_gki_support() {
    local major="$1"
    local minor="$2"
    
    # GKI support started in 4.19 but mainly for 5.4+
    if [ "$major" -gt 5 ] || ([ "$major" = 5 ] && [ "$minor" -ge 4 ]); then
        echo "gki_supported"
    elif [ "$major" = 4 ] && [ "$minor" -ge 19 ]; then
        echo "gki_experimental"
    else
        echo "non_gki"
    fi
}

main() {
    # Get kernel version info
    local version_info=$(get_kernel_version)
    
    local version=$(echo "$version_info" | cut -d'|' -f1)
    local patchlevel=$(echo "$version_info" | cut -d'|' -f2)
    local sublevel=$(echo "$version_info" | cut -d'|' -f3)
    local extraversion=$(echo "$version_info" | cut -d'|' -f4)
    local name=$(echo "$version_info" | cut -d'|' -f5)
    
    local full_version=$(get_full_version "$version" "$patchlevel" "$sublevel" "$extraversion")
    local kernel_family=$(get_kernel_family "$version" "$patchlevel")
    local arch=$(get_arch)
    local defconfig=$(get_defconfig)
    local gki_status=$(check_gki_support "$version" "$patchlevel")
    
    # Output
    if [ "$OUTPUT_JSON" = true ]; then
        cat <<EOF
{
  "kernel": {
    "version": $version,
    "patchlevel": $patchlevel,
    "sublevel": $sublevel,
    "extraversion": "$extraversion",
    "full_version": "$full_version",
    "name": "$name"
  },
  "family": "$kernel_family",
  "arch": "$arch",
  "defconfig": "$defconfig",
  "gki_status": "$gki_status"
}
EOF
    else
        echo "========================================"
        echo "  Kernel Version Detection"
        echo "========================================"
        echo ""
        echo "Full Version: $full_version"
        echo "Family: $kernel_family"
        echo "Architecture: $arch"
        echo ""
        echo "Components:"
        echo "  VERSION: $version"
        echo "  PATCHLEVEL: $patchlevel"
        echo "  SUBLEVEL: $sublevel"
        echo "  EXTRAVERSION: $extraversion"
        if [ -n "$name" ]; then
            echo "  NAME: $name"
        fi
        echo ""
        echo "Defconfig: $defconfig"
        echo "GKI Status: $gki_status"
        echo ""
        
        # Special notes
        if [ "$gki_status" = "non_gki" ]; then
            echo -e "${YELLOW}Note: This kernel requires Non-GKI build method.${NC}"
        elif [ "$gki_status" = "gki_experimental" ]; then
            echo -e "${YELLOW}Note: GKI support is experimental for this kernel.${NC}"
        fi
        echo ""
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

main "$@"
