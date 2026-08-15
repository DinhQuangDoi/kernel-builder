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

# LEGACY inline hooks (tier 1): ksu_handle_* trong host files.
declare -A LEGACY_HOOK_FILE
LEGACY_HOOK_FILE["fs/exec.c"]="ksu_handle_execveat ksu_handle_execve"
LEGACY_HOOK_FILE["fs/open.c"]="ksu_handle_faccessat"
LEGACY_HOOK_FILE["fs/stat.c"]="ksu_handle_stat ksu_handle_newfstatat ksu_handle_fstat64_ret"
LEGACY_HOOK_FILE["kernel/sys.c"]="ksu_handle_setresuid ksu_handle_sys_reboot"
LEGACY_HOOK_FILE["fs/read_write.c"]="ksu_handle_sys_read"
LEGACY_HOOK_FILE["kernel/reboot.c"]="ksu_handle_sys_reboot"
LEGACY_HOOK_FILE["drivers/input/input.c"]="ksu_handle_input_handle_event"

# CURRENT dispatcher (tier 2): ksu_hook_* trong syscall_hook_manager.c
CURRENT_DISPATCHER_FILE="kernel/syscall_hook_manager.c"
CURRENT_DISPATCHER_SYMBOLS=(ksu_hook_setresuid ksu_hook_execve ksu_hook_newfstatat ksu_hook_faccessat)

# CURRENT LSM (tier 2): ksu_handle_path_truncate/task_alloc/task_free, patch động
CURRENT_LSM_SYMBOLS=(ksu_handle_path_truncate ksu_handle_task_alloc ksu_handle_task_free)

# Legacy compat residue (old style, cần cleanup)
COMPAT_OLD_HOOKS=(ksu_vfs_read_hook ksu_input_hook ksu_execveat_hook ksu_init_rc_hook ksu_vfs_write_hook ksu_stat_hook ksu_setresuid_hook ksu_reboot_hook ksu_faccessat_hook ksu_handle_rename)

check_hooks_in_files() {
    local hooks_found=0
    local incompatible_found=0
    local legacy_found=0
    local current_found=0
    local dispatcher_found=0
    local lsm_found=0
    local compat_found=0

    # Legacy inline (tier 1)
    for file in "${!LEGACY_HOOK_FILE[@]}"; do
        if [ -f "$file" ]; then
            local syms=(${LEGACY_HOOK_FILE[$file]})
            for sym in "${syms[@]}"; do
                if grep -q "\b${sym}\b" "$file" 2>/dev/null; then
                    ((legacy_found++))
                    print_info "LEGACY hook: $sym in $file"
                fi
            done
        fi
    done

    # CURRENT dispatcher (tier 2)
    if [ -f "$CURRENT_DISPATCHER_FILE" ]; then
        local d=0
        for sym in "${CURRENT_DISPATCHER_SYMBOLS[@]}"; do
            grep -q "\b${sym}\b" "$CURRENT_DISPATCHER_FILE" 2>/dev/null && ((d++))
        done
        dispatcher_found=$d
    fi

    # CURRENT LSM (tier 2) - patch động, grep symbol trong source
    local l=0
    for sym in "${CURRENT_LSM_SYMBOLS[@]}"; do
        if grep -rq "\b${sym}\b" --include="*.c" --include="*.h" . 2>/dev/null; then
            ((l++))
        fi
    done
    lsm_found=$l

    # Legacy compat residue
    for file in "${!LEGACY_HOOK_FILE[@]}"; do
        if [ -f "$file" ]; then
            for hook in "${COMPAT_OLD_HOOKS[@]}"; do
                if grep -q "\b${hook}\b" "$file" 2>/dev/null; then
                    ((compat_found++))
                    print_info "COMPAT residue: $hook in $file"
                fi
            done
        fi
    done

    current_found=$((dispatcher_found + lsm_found))

    if [ $((legacy_found + current_found + compat_found)) -gt 0 ]; then
        hooks_found=1
    fi

    incompatible_found=$compat_found

    # hooks_found|incompatible|legacy|current|dispatcher|lsm|compat
    echo "$hooks_found|$incompatible_found|$legacy_found|$current_found|$dispatcher_found|$lsm_found|$compat_found"
}

check_config_ksu() {
    local config_found=false
    local config_value=""
    local ksu_version=""
    
    local defconfigs=$(find . -name "*defconfig*" -type f 2>/dev/null | head -20)
    
    for file in $defconfigs; do
        if grep -q "CONFIG_KSU" "$file" 2>/dev/null; then
            config_found=true
            config_value=$(grep "CONFIG_KSU" "$file" 2>/dev/null | head -1)
            break
        fi
    done

    if [ -f "drivers/kernelsu/version.h" ]; then
        ksu_version=$(grep -oP 'Kernelsu_VERSION\s+\K[0-9.]+' "drivers/kernelsu/version.h" 2>/dev/null || echo "")
    elif [ -f "drivers/kernelsu/version" ]; then
        ksu_version=$(cat "drivers/kernelsu/version" 2>/dev/null || echo "")
    fi
    
    if [ "$config_found" = true ]; then
        echo "enabled|$config_value|$ksu_version"
    else
        echo "disabled||$ksu_version"
    fi
}

# Suy ksu_generation từ hooks: current > legacy > compat.
git_is_shallow() {
    if [ ! -d ".git" ]; then
        return 1
    fi
    if git rev-parse --is-shallow-repository 2>/dev/null | grep -q "true"; then
        return 0
    fi
    if [ "$(git rev-list --count --all 2>/dev/null || echo 0)" -lt 10 ]; then
        return 0
    fi
    return 1
}

infer_generation() {
    local hooks="$1"
    local current=$(echo "$hooks" | cut -d'|' -f4)
    local legacy=$(echo "$hooks" | cut -d'|' -f3)
    local compat=$(echo "$hooks" | cut -d'|' -f7)
    if [ "$compat" -gt 0 ]; then
        echo "compat"
    elif [ "$current" -gt 0 ]; then
        echo "current"
    elif [ "$legacy" -gt 0 ]; then
        echo "legacy"
    else
        echo ""
    fi
}

check_recent_ksu_commits() {
    local commits_found=0
    
    if [ -d ".git" ] && git_is_shallow; then
        echo "0"
        return 0
    fi
    
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
    local legacy=$(echo "$hooks" | cut -d'|' -f3)
    local current=$(echo "$hooks" | cut -d'|' -f4)
    local compat=$(echo "$hooks" | cut -d'|' -f7)
    
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
        recommendation="Legacy COMPAT hooks found. Recommend cleanup before new integration."
        needs_cleanup=true
    elif [ "$current" -gt 0 ]; then
        recommendation="Current-gen KSU hooks found (dispatcher/LSM). Integration OK."
        ready_for_integration=true
    elif [ "$legacy" -gt 0 ]; then
        recommendation="Legacy inline KSU hooks found. May need update."
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
    local legacy_found=$(echo "$hooks_result" | cut -d'|' -f3)
    local current_found=$(echo "$hooks_result" | cut -d'|' -f4)
    local dispatcher_found=$(echo "$hooks_result" | cut -d'|' -f5)
    local lsm_found=$(echo "$hooks_result" | cut -d'|' -f6)
    local compat_found=$(echo "$hooks_result" | cut -d'|' -f7)
    
    local config_status=$(echo "$config_result" | cut -d'|' -f1)
    local config_version=$(echo "$config_result" | cut -d'|' -f3)
    [ -z "$config_version" ] && config_version="$ksu_version"
    
    local generation=$(infer_generation "$hooks_result")
    local git_shallow="false"
    if git_is_shallow; then
        git_shallow="true"
    fi
    [ "$git_shallow" = "true" ] && print_info "[SHALLOW] git history not available (depth 1)"
    
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
    "dispatcher": $dispatcher_found,
    "lsm": $lsm_found,
    "legacy": $legacy_found,
    "compat": $compat_found,
    "incompatible": $incompatible_found
  },
  "ksu_generation": "$generation",
  "git_shallow": $git_shallow,
  "config_ksu": "$config_status",
  "ksu_version": "$config_version",
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
        echo "  Legacy inline: $legacy_found"
        echo "  Current dispatcher: $dispatcher_found"
        echo "  Current LSM: $lsm_found"
        echo "  Legacy compat residue: $compat_found"
        echo "  Incompatible (old style): $incompatible_found"
        echo "  Generation: $generation"
        echo ""
        echo -e "${BOLD}Config:${NC}"
        echo "  CONFIG_KSU: $config_status"
        echo "  KSU_VERSION: $config_version"
        echo ""
        echo -e "${BOLD}Git History:${NC}"
        echo "  KSU-related commits: $commits"
        echo "  Shallow clone: $git_shallow"
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
