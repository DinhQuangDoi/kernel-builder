#!/bin/bash
# detect-old-ksu.sh - Tìm và phân tích KSU hooks cũ trong kernel source
# Version: 1.0.0

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# KSU hooks cũ (incompatible) cần tìm
OLD_INCOMPATIBLE_HOOKS=(
    "ksu_vfs_read_hook"
    "ksu_input_hook"
    "ksu_execveat_hook"
    "ksu_init_rc_hook"
    "ksu_vfs_write_hook"
    "ksu_stat_hook"
    "ksu_setresuid_hook"
    "ksu_reboot_hook"
    "ksu_faccessat_hook"
)

# Files thường chứa KSU hooks
KSU_HOOK_FILES=(
    "fs/exec.c"
    "fs/open.c"
    "fs/read_write.c"
    "fs/stat.c"
    "kernel/sys.c"
    "kernel/reboot.c"
    "drivers/input/input.c"
    "kernel/cred.c"
)

# Các commit message patterns liên quan đến KSU
KSU_COMMIT_PATTERNS=(
    "ksu"
    "kernelsu"
    "KernelSU"
    "susfs"
)

# Output files
REPORT_FILE="ksu_old_hooks_report.txt"

# Functions
print_header() {
    echo -e "${BOLD}${BLUE}========================================${NC}"
    echo -e "${BOLD}${BLUE}  KSU Old Hooks Detector v1.0${NC}"
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

check_git_repo() {
    if [ ! -d ".git" ]; then
        print_warning "Khong phai git repository. Chi co the scan files truc tiep."
        return 1
    fi
    return 0
}

scan_files_for_old_hooks() {
    print_info "Scanning files for old KSU hooks..."
    echo ""
    
    local found_any=false
    
    for file in "${KSU_HOOK_FILES[@]}"; do
        if [ -f "$file" ]; then
            local file_found=false
            local incompatible_found=false
            local hook_details=""
            
            for hook in "${OLD_INCOMPATIBLE_HOOKS[@]}"; do
                if grep -q "$hook" "$file" 2>/dev/null; then
                    file_found=true
                    incompatible_found=true
                    hook_details+="  - ${RED}INCOMPATIBLE: $hook${NC}\n"
                fi
            done
            
            # Check cho hooks moi (khong co prefix ksu_)
            if grep -q "ksu_handle_" "$file" 2>/dev/null; then
                file_found=true
                hook_details+="  - ${GREEN}NEW STYLE: ksu_handle_* hooks${NC}\n"
            fi
            
            if [ "$file_found" = true ]; then
                found_any=true
                echo -e "File: ${BOLD}$file${NC}"
                echo -e "$hook_details"
                
                # Lay thong tin tu git log
                if [ -d ".git" ]; then
                    local commits=$(git log --oneline -5 --all -- "$file" 2>/dev/null | head -3)
                    if [ -n "$commits" ]; then
                        echo "  Recent commits:"
                        echo "$commits" | while read -r line; do
                            echo "    - $line"
                        done
                    fi
                fi
                echo ""
            fi
        fi
    done
    
    if [ "$found_any" = false ]; then
        print_success "Khong tim thay old KSU hooks trong cac file thong thuong."
    fi
    
    return 0
}

scan_git_history_for_ksu() {
    print_info "Scanning git history for KSU-related commits..."
    echo ""
    
    if [ ! -d ".git" ]; then
        print_warning "Khong co .git - skip git history scan."
        return 0
    fi
    
    local ksu_commits=$(git log --all --oneline --grep="ksu" --grep="kernelsu" --grep="KernelSU" --grep="susfs" -i 2>/dev/null | head -20)
    
    if [ -n "$ksu_commits" ]; then
        echo -e "${YELLOW}Found KSU-related commits:${NC}"
        echo "$ksu_commits" | while read -r line; do
            echo "  - $line"
        done
        echo ""
        return 1
    else
        print_success "Khong tim thay KSU commits trong git history."
        echo ""
        return 0
    fi
}

scan_susfs_files() {
    print_info "Checking for Susfs files..."
    echo ""
    
    local susfs_files=(
        "fs/susfs.c"
        "include/linux/susfs.h"
        "include/linux/susfs_def.h"
    )
    
    local found_susfs=false
    
    for file in "${susfs_files[@]}"; do
        if [ -f "$file" ]; then
            found_susfs=true
            echo -e "  - ${RED}$file${NC} (exists - may be old version)"
            
            # Check version
            if grep -q "SUSFS_VERSION" "$file" 2>/dev/null; then
                local version=$(grep "SUSFS_VERSION" "$file" | head -1)
                echo "    $version"
            fi
        fi
    done
    
    if [ "$found_susfs" = true ]; then
        echo ""
        print_warning "Old Susfs files found - recommend removal before integration."
        echo ""
        return 1
    else
        print_success "No old Susfs files found."
        echo ""
        return 0
    fi
}

scan_kernelsu_dir() {
    print_info "Checking for drivers/kernelsu directory..."
    echo ""
    
    if [ -d "drivers/kernelsu" ]; then
        echo -e "  - ${YELLOW}drivers/kernelsu/${NC} (exists)"
        
        # Check version
        if [ -f "drivers/kernelsu/version.h" ]; then
            local version=$(grep "Kernelsu_VERSION" "drivers/kernelsu/version.h" 2>/dev/null | head -1)
            if [ -n "$version" ]; then
                echo "    $version"
            fi
        fi
        
        echo ""
        print_warning "Existing KernelSU found - may conflict with new integration."
        echo ""
        return 1
    else
        print_success "No existing KernelSU directory found."
        echo ""
        return 0
    fi
}

check_config_ksu() {
    print_info "Checking for CONFIG_KSU in defconfigs..."
    echo ""
    
    local defconfig_files=$(find . -name "*defconfig*" -type f 2>/dev/null | head -10)
    
    local found_config=false
    for file in $defconfig_files; do
        if grep -q "CONFIG_KSU" "$file" 2>/dev/null; then
            found_config=true
            echo -e "  - ${YELLOW}$file${NC}: CONFIG_KSU found"
        fi
    done
    
    if [ "$found_config" = true ]; then
        echo ""
        print_warning "CONFIG_KSU found in defconfigs."
        echo ""
        return 1
    else
        print_success "No CONFIG_KSU found in defconfigs."
        echo ""
        return 0
    fi
}

generate_summary() {
    echo ""
    echo -e "${BOLD}${BLUE}========================================${NC}"
    echo -e "${BOLD}${BLUE}  SUMMARY${NC}"
    echo -e "${BOLD}${BLUE}========================================${NC}"
    echo ""
    
    local needs_cleanup=false
    
    # Check incompatible hooks
    for file in "${KSU_HOOK_FILES[@]}"; do
        if [ -f "$file" ]; then
            for hook in "${OLD_INCOMPATIBLE_HOOKS[@]}"; do
                if grep -q "$hook" "$file" 2>/dev/null; then
                    needs_cleanup=true
                    break 2
                fi
            done
        fi
    done
    
    if [ -d "drivers/kernelsu" ] || [ -f "fs/susfs.c" ] || [ "$needs_cleanup" = true ]; then
        echo -e "${YELLOW}Old KSU detected - cleanup recommended before integration:${NC}"
        echo ""
        echo "  1. Run: ./ksu-cleanup-helper.sh"
        echo "  2. This will safely remove old KSU hooks"
        echo "  3. Then proceed with new ReSukiSU integration"
        echo ""
        return 1
    else
        echo -e "${GREEN}No old KSU found - ready for new integration!${NC}"
        echo ""
        echo "  Proceed directly with ReSukiSU integration."
        echo ""
        return 0
    fi
}

# Main execution
main() {
    print_header
    
    # Check if running in kernel source directory
    if [ ! -f "Makefile" ]; then
        print_warning "Khong tim thay Makefile - co the khong phai kernel source."
        read -p "Van tiep tuc? (y/n): " confirm
        if [ "$confirm" != "y" ]; then
            exit 0
        fi
    fi
    
    echo "Kernel source detected: $(pwd)"
    echo ""
    
    # Run all scans (results are printed by each scan, then re-verified in summary)
    scan_kernelsu_dir || true
    scan_susfs_files || true
    scan_files_for_old_hooks || true
    scan_git_history_for_ksu || true
    check_config_ksu || true
    
    # Generate summary
    generate_summary
    
    exit $?
}

# Run
main "$@"
