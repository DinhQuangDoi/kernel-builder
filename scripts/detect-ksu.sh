#!/bin/bash
# detect-ksu.sh - Check existing KSU/Susfs status in kernel source
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

check_kernelsu_directory() {
    local result="not_found"
    local version="unknown"
    
    if [ -d "drivers/kernelsu" ]; then
        result="found"
        
        # Check version
        if [ -f "drivers/kernelsu/version.h" ]; then
            version=$(grep -oP 'Kernelsu_VERSION\s+\K[0-9.]+' "drivers/kernelsu/version.h" 2>/dev/null || echo "unknown")
        elif [ -f "drivers/kernelsu/version" ]; then
            version=$(cat "drivers/kernelsu/version" 2>/dev/null || echo "unknown")
        fi
        
        # Check for ReSukiSU specific files
        if [ -d "drivers/kernelsu/ksu" ]; then
            result="resukisu"
        fi
    fi
    
    echo "$result|$version"
}

check_susfs_files() {
    local susfs_found="not_found"
    local susfs_version="unknown"
    
    local susfs_files=(
        "fs/susfs.c"
        "include/linux/susfs.h"
        "include/linux/susfs_def.h"
    )
    
    local found_count=0
    for file in "${susfs_files[@]}"; do
        if [ -f "$file" ]; then
            ((found_count++))
        fi
    done
    
    if [ $found_count -eq 3 ]; then
        susfs_found="complete"
    elif [ $found_count -gt 0 ]; then
        susfs_found="partial"
    fi
    
    # Check version
    if [ -f "include/linux/susfs.h" ]; then
        susfs_version=$(grep -oP 'SUSFS_VERSION\s+"[^"]+"' "include/linux/susfs.h" 2>/dev/null | cut -d'"' -f2 || echo "unknown")
    fi
    
    echo "$susfs_found|$susfs_version"
}

check_hooks_in_files() {
    local hooks_found=0
    local incompatible_found=0
    local new_style_found=0
    
    # Files to check
    local hook_files=(
        "fs/exec.c"
        "fs/open.c"
        "fs/read_write.c"
        "fs/stat.c"
        "kernel/sys.c"
        "kernel/reboot.c"
        "drivers/input/input.c"
    )
    
    # Incompatible hooks (old style)
    local incompatible_hooks=(
        "ksu_vfs_read_hook"
        "ksu_input_hook"
        "ksu_execveat_hook"
        "ksu_init_rc_hook"
    )
    
    for file in "${hook_files[@]}"; do
        if [ -f "$file" ]; then
            # Check for new style hooks
            if grep -q "ksu_handle_" "$file" 2>/dev/null; then
                ((new_style_found++))
            fi
            
            # Check for incompatible hooks
            for hook in "${incompatible_hooks[@]}"; do
                if grep -q "$hook" "$file" 2>/dev/null; then
                    ((incompatible_found++))
                    print_info "Found incompatible hook: $hook in $file"
                fi
            done
        fi
    done
    
    if [ $new_style_found -gt 0 ]; then
        hooks_found=1
    fi
    
    echo "$hooks_found|$incompatible_found|$new_style_found"
}

check_config_ksu() {
    local config_found=false
    local config_value=""
    
    local defconfigs=$(find . -name "*defconfig*" -type f 2>/dev/null | head -20)
    
    for file in $defconfigs; do
        if grep -q "CONFIG_KSU" "$file" 2>/dev/null; then
            config_found=true
            config_value=$(grep "CONFIG_KSU" "$file" 2>/dev/null | head -1)
            break
        fi
    done
    
    if [ "$config_found" = true ]; then
        echo "enabled|$config_value"
    else
        echo "disabled|"
    fi
}

check_recent_ksu_commits() {
    local commits_found=0
    
    if [ -d ".git" ]; then
        commits_found=$(git log --all --oneline --grep="ksu\|kernelsu\|KernelSU" -i 2>/dev/null | wc -l | tr -d ' ')
    fi
    
    echo "$commits_found"
}

generate_recommendation() {
    local ksu_dir="$1"
    local susfs="$2"
    local hooks="$3"
    local config="$4"
    local commits="$5"
    
    local incompatible=$(echo "$hooks" | cut -d'|' -f2)
    local new_style=$(echo "$hooks" | cut -d'|' -f3)
    
    local needs_cleanup=false
    local ready_for_integration=false
    local recommendation=""
    
    if [ "$ksu_dir" = "found" ] || [ "$ksu_dir" = "resukisu" ]; then
        if [ "$ksu_dir" = "resukisu" ]; then
            recommendation="ReSukiSU already integrated. Skip integration."
            ready_for_integration=false
        else
            recommendation="Old KernelSU found. Recommend cleanup before new integration."
            needs_cleanup=true
        fi
    elif [ "$susfs" != "not_found" ]; then
        recommendation="Old Susfs found. Recommend cleanup before new integration."
        needs_cleanup=true
    elif [ "$incompatible" -gt 0 ]; then
        recommendation="Incompatible hooks found. Recommend cleanup before new integration."
        needs_cleanup=true
    elif [ "$new_style" -gt 0 ]; then
        recommendation="New style KSU hooks found. May need update."
        ready_for_integration=true
    elif [ "$commits" -gt 0 ]; then
        recommendation="KSU commits found in history. Review recommended."
    else
        recommendation="No KSU detected. Ready for new integration!"
        ready_for_integration=true
    fi
    
    echo "$recommendation"
}

main() {
    print_info "Checking KSU/Susfs status..."
    
    # Run all checks
    local ksu_result=$(check_kernelsu_directory)
    local susfs_result=$(check_susfs_files)
    local hooks_result=$(check_hooks_in_files)
    local config_result=$(check_config_ksu)
    local commits=$(check_recent_ksu_commits)
    
    # Parse results
    local ksu_status=$(echo "$ksu_result" | cut -d'|' -f1)
    local ksu_version=$(echo "$ksu_result" | cut -d'|' -f2)
    
    local susfs_status=$(echo "$susfs_result" | cut -d'|' -f1)
    local susfs_version=$(echo "$susfs_result" | cut -d'|' -f2)
    
    local hooks_found=$(echo "$hooks_result" | cut -d'|' -f1)
    local incompatible_found=$(echo "$hooks_result" | cut -d'|' -f2)
    local new_style_found=$(echo "$hooks_result" | cut -d'|' -f3)
    
    local config_status=$(echo "$config_result" | cut -d'|' -f1)
    
    # Generate recommendation
    local recommendation=$(generate_recommendation "$ksu_status" "$susfs_status" "$hooks_result" "$config_status" "$commits")
    
    # Output
    if [ "$OUTPUT_JSON" = true ]; then
        cat <<EOF
{
  "ksu": {
    "status": "$ksu_status",
    "version": "$ksu_version"
  },
  "susfs": {
    "status": "$susfs_status",
    "version": "$susfs_version"
  },
  "hooks": {
    "new_style": $new_style_found,
    "incompatible": $incompatible_found
  },
  "config_ksu": "$config_status",
  "recent_commits": $commits,
  "recommendation": "$recommendation"
}
EOF
    else
        echo "========================================"
        echo "  KSU/Susfs Status Detection"
        echo "========================================"
        echo ""
        echo -e "${BOLD}KernelSU:${NC}"
        echo "  Status: $ksu_status"
        echo "  Version: $ksu_version"
        echo ""
        echo -e "${BOLD}Susfs:${NC}"
        echo "  Status: $susfs_status"
        echo "  Version: $susfs_version"
        echo ""
        echo -e "${BOLD}Hooks:${NC}"
        echo "  New Style (ksu_handle_*): $new_style_found"
        echo "  Incompatible (old style): $incompatible_found"
        echo ""
        echo -e "${BOLD}Config:${NC}"
        echo "  CONFIG_KSU: $config_status"
        echo ""
        echo -e "${BOLD}Git History:${NC}"
        echo "  KSU-related commits: $commits"
        echo ""
        echo -e "${BOLD}Recommendation:${NC}"
        echo "  $recommendation"
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
