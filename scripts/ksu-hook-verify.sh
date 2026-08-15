#!/bin/bash
# ksu-hook-verify.sh - Verify KSU hooks are properly installed using inline_hook_check.mk
# Version: 1.0.0
# Requires: ReSukiSU kernel tools

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
    echo -e "${BOLD}${BLUE}  KSU Hook Verification${NC}"
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

check_tools_exist() {
    if [ ! -f "${TOOLS_DIR}/inline_hook_check.mk" ]; then
        print_warning "inline_hook_check.mk not found in ${TOOLS_DIR}"
        print_info "Downloading from ReSukiSU..."
        
        mkdir -p "${TOOLS_DIR}"
        curl -sL "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/tools/inline_hook_check.mk" \
            -o "${TOOLS_DIR}/inline_hook_check.mk" 2>/dev/null || {
            print_error "Failed to download inline_hook_check.mk"
            return 1
        }
    fi
    
    return 0
}

check_incompatible_hooks() {
    echo -e "${BOLD}Checking for INCOMPATIBLE hooks (legacy COMPAT residue):${NC}"
    echo ""
    
    local incompatible_found=0
    
    # Incompatible hooks from inline_hook_check.mk
    local incompatible_hooks=(
        "ksu_vfs_read_hook:fs/read_write.c:Old vfs_read hook - should be replaced"
        "ksu_input_hook:drivers/input/input.c:Old input hook - should be replaced"
        "ksu_execveat_hook:fs/exec.c:Old execveat hook - should be replaced"
        "ksu_init_rc_hook:fs/read_write.c:Old init_rc hook - should be replaced"
        "ksu_init_rc_hook:fs/stat.c:Old init_rc hook - should be replaced"
    )
    
    for hook_info in "${incompatible_hooks[@]}"; do
        IFS=':' read -r hook file desc <<< "$hook_info"
        
        if [ -f "$file" ] && grep -q "$hook" "$file" 2>/dev/null; then
            print_error "Found INCOMPATIBLE hook: $hook in $file"
            print_info "$desc"
            ((incompatible_found++))
        fi
    done
    
    echo ""
    
    if [ $incompatible_found -gt 0 ]; then
        print_warning "Found $incompatible_found incompatible hook(s)"
        print_info "Run ksu-cleanup-helper.sh to remove old hooks"
        return 1
    else
        print_success "No incompatible hooks found"
        return 0
    fi
}

check_required_hooks() {
    # Công cụ này xác minh SUSFS INLINE integration: ksu_handle_* inline hooks
    # trong host files (= LEGACY tier). Với SUSFS inline, các hook inline là bắt
    # buộc. Chỉ khi integration dạng CURRENT (dispatcher+LSM) mới không cần.
    echo -e "${BOLD}Checking for REQUIRED inline hooks (SUSFS inline / LEGACY tier):${NC}"
    echo ""
    
    local hooks_found=0
    local hooks_missing=0
    
    # Required hooks (inline, LEGACY tier) from inline_hook_check.mk
    local required_hooks=(
        "ksu_handle_setresuid:kernel/sys.c"
        "ksu_handle_execveat:fs/exec.c"
        "ksu_handle_faccessat:fs/open.c"
        "ksu_handle_sys_read:fs/read_write.c"
        "ksu_handle_stat:fs/stat.c"
        "ksu_handle_sys_reboot:kernel/reboot.c"
        "ksu_handle_input_handle_event:drivers/input/input.c"
    )
    
    for hook_info in "${required_hooks[@]}"; do
        IFS=':' read -r hook file <<< "$hook_info"
        
        if [ -f "$file" ]; then
            if grep -q "$hook" "$file" 2>/dev/null; then
                print_success "$hook found in $file"
                ((hooks_found++))
            else
                print_warning "$hook NOT found in $file"
                ((hooks_missing++))
            fi
        else
            print_warning "File $file not found - skipping"
            ((hooks_missing++))
        fi
    done
    
    echo ""
    
    return $hooks_missing
}

check_manual_guards() {
    echo -e "${BOLD}Checking for CONFIG_KSU_MANUAL_HOOK guards:${NC}"
    echo ""
    
    local guards_found=0
    
    # Files that might have manual guards
    local guard_files=(
        "kernel/sys.c"
        "fs/exec.c"
        "fs/open.c"
        "fs/read_write.c"
        "fs/stat.c"
        "kernel/reboot.c"
        "drivers/input/input.c"
    )
    
    for file in "${guard_files[@]}"; do
        if [ -f "$file" ] && grep -q "CONFIG_KSU_MANUAL_HOOK" "$file" 2>/dev/null; then
            print_warning "Found CONFIG_KSU_MANUAL_HOOK in $file"
            print_info "This may cause build issues"
            ((guards_found++))
        fi
    done
    
    echo ""
    
    if [ $guards_found -gt 0 ]; then
        print_warning "Found $guards_found file(s) with MANUAL_HOOK guards"
        print_info "Consider removing CONFIG_KSU_MANUAL_HOOK for automatic hooks"
    else
        print_success "No MANUAL_HOOK guards found"
    fi
    
    echo ""
    return $guards_found
}

check_kernelsu_directory() {
    echo -e "${BOLD}Checking drivers/kernelsu directory:${NC}"
    echo ""
    
    if [ -d "drivers/kernelsu" ]; then
        print_success "drivers/kernelsu/ exists"
        
        # Check for essential files
        local essential_files=(
            "kernelsu.c"
            "Kconfig"
            "Makefile"
        )
        
        for file in "${essential_files[@]}"; do
            if [ -f "drivers/kernelsu/$file" ]; then
                print_success "  - $file found"
            else
                print_warning "  - $file NOT found"
            fi
        done
        
        echo ""
        return 0
    else
        print_error "drivers/kernelsu/ NOT found"
        print_info "Run ReSukiSU integration first"
        echo ""
        return 1
    fi
}

check_susfs_integration() {
    echo -e "${BOLD}Checking Susfs integration:${NC}"
    echo ""
    
    local susfs_files=(
        "fs/susfs.c"
        "include/linux/susfs.h"
        "include/linux/susfs_def.h"
    )
    
    local found_count=0
    
    for file in "${susfs_files[@]}"; do
        if [ -f "$file" ]; then
            print_success "$file found"
            ((found_count++))
        fi
    done
    
    echo ""
    
    if [ $found_count -eq 3 ]; then
        print_success "Susfs fully integrated"
        return 0
    elif [ $found_count -gt 0 ]; then
        print_warning "Susfs partially integrated ($found_count/3 files)"
        return 1
    else
        print_warning "Susfs not integrated"
        return 2
    fi
}

generate_summary() {
    local incompatible=$1
    local missing=$2
    local guards=$3
    local ksu_dir=$4
    local susfs=$5
    
    echo -e "${BOLD}${BLUE}========================================${NC}"
    echo -e "${BOLD}${BLUE}  Hook Verification Summary${NC}"
    echo -e "${BOLD}${BLUE}========================================${NC}"
    echo ""
    
    local has_issues=false
    local has_errors=false
    
    if [ $incompatible -gt 0 ]; then
        echo -e "  Incompatible hooks: ${RED}$incompatible${NC}"
        has_errors=true
    else
        echo -e "  Incompatible hooks: ${GREEN}0${NC}"
    fi
    
    if [ $missing -gt 0 ]; then
        echo -e "  Missing required hooks: ${RED}$missing${NC}"
        has_errors=true
    else
        echo -e "  Missing required hooks: ${GREEN}0${NC}"
    fi
    
    if [ $guards -gt 0 ]; then
        echo -e "  Manual hook guards: ${YELLOW}$guards${NC}"
        has_issues=true
    else
        echo -e "  Manual hook guards: ${GREEN}0${NC}"
    fi
    
    if [ $ksu_dir -ne 0 ]; then
        echo -e "  KernelSU directory: ${RED}MISSING${NC}"
        has_errors=true
    else
        echo -e "  KernelSU directory: ${GREEN}OK${NC}"
    fi
    
    if [ $susfs -ne 0 ]; then
        if [ $susfs -eq 2 ]; then
            echo -e "  Susfs integration: ${RED}NOT INTEGRATED${NC}"
            has_errors=true
        else
            echo -e "  Susfs integration: ${YELLOW}PARTIAL${NC}"
            has_issues=true
        fi
    else
        echo -e "  Susfs integration: ${GREEN}OK${NC}"
    fi
    
    echo ""
    
    if [ "$has_errors" = true ]; then
        echo -e "Status: ${RED}FAILED${NC}"
        echo ""
        echo "Please fix the errors above before building."
        return 1
    elif [ "$has_issues" = true ]; then
        echo -e "Status: ${YELLOW}WARNINGS${NC}"
        echo ""
        echo "There are warnings but integration may still work."
        return 2
    else
        echo -e "Status: ${GREEN}PASSED${NC}"
        echo ""
        echo "All hooks are properly installed!"
        return 0
    fi
}

main() {
    print_header
    
    # Check if in kernel source
    if [ ! -f "Makefile" ]; then
        print_error "Makefile not found. Run in kernel source directory."
        exit 1
    fi
    
    # Check tools
    check_tools_exist || exit 1
    
    # Run all checks
    local incompatible_result=$(check_incompatible_hooks)
    local incompatible=$?
    
    local missing_result=$(check_required_hooks)
    local missing=$?
    
    local guards_result=$(check_manual_guards)
    local guards=$?
    
    local ksu_dir_result=$(check_kernelsu_directory)
    local ksu_dir=$?
    
    local susfs_result=$(check_susfs_integration)
    local susfs=$?
    
    # Generate summary
    generate_summary $incompatible $missing $guards $ksu_dir $susfs
    
    exit $?
}

main "$@"
