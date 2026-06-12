#!/bin/bash
# ksu-cleanup-helper.sh - Safely remove old KSU hooks without affecting other code
# Version: 1.0.0

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Incompatible hooks that need to be removed
INCOMPATIBLE_HOOKS=(
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

# Files that commonly contain KSU hooks
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

# Susfs files to remove
SUSFS_FILES=(
    "fs/susfs.c"
    "include/linux/susfs.h"
    "include/linux/susfs_def.h"
)

# Backup directory
BACKUP_DIR="ksu_cleanup_backup_$(date +%Y%m%d_%H%M%S)"

# Functions
print_header() {
    echo -e "${BOLD}${RED}========================================${NC}"
    echo -e "${BOLD}${RED}  KSU Old Hooks Cleanup Helper v1.0${NC}"
    echo -e "${BOLD}${RED}========================================${NC}"
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

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

confirm() {
    echo -e "${YELLOW}$1${NC}"
    read -p "Continue? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        echo "Cancelled."
        exit 0
    fi
}

backup_current_state() {
    print_step "Creating backup..."
    
    mkdir -p "$BACKUP_DIR"
    
    # Backup KSU-related files
    for file in "${KSU_HOOK_FILES[@]}"; do
        if [ -f "$file" ]; then
            mkdir -p "$BACKUP_DIR/$(dirname $file)"
            cp "$file" "$BACKUP_DIR/$file"
            echo "  Backed up: $file"
        fi
    done
    
    # Backup Susfs files
    for file in "${SUSFS_FILES[@]}"; do
        if [ -f "$file" ]; then
            mkdir -p "$BACKUP_DIR/$(dirname $file)"
            cp "$file" "$BACKUP_DIR/$file"
            echo "  Backed up: $file"
        fi
    done
    
    # Backup KSU directory
    if [ -d "drivers/kernelsu" ]; then
        cp -r "drivers/kernelsu" "$BACKUP_DIR/"
        echo "  Backed up: drivers/kernelsu/"
    fi
    
    print_success "Backup created in: $BACKUP_DIR"
    echo ""
}

remove_incompatible_hooks_from_file() {
    local file="$1"
    
    if [ ! -f "$file" ]; then
        return 0
    fi
    
    local changes_made=false
    
    for hook in "${INCOMPATIBLE_HOOKS[@]}"; do
        # Skip new-style hooks
        if [[ "$hook" == ksu_handle_* ]]; then
            continue
        fi
        
        # Check if hook exists in file
        if grep -q "$hook" "$file" 2>/dev/null; then
            # Pattern 1: Remove function definition with body
            # Match: return_type hook(args) { ... }
            sed -i "s/^.*$hook.*(.*).*{[^}]*}//g" "$file" 2>/dev/null || true
            
            # Pattern 2: Remove extern declaration
            sed -i "s/^extern.*$hook.*;//g" "$file" 2>/dev/null || true
            
            # Pattern 3: Remove call sites: ksu_hook();
            sed -i "s/$hook();//g" "$file" 2>/dev/null || true
            
            # Pattern 4: Remove if containing ksu_hook
            sed -i "/if.*($hook)/d" "$file" 2>/dev/null || true
            
            # Pattern 5: Remove assignments: ksu_hook = ...
            sed -i "s/$hook\s*=/\/\/ $hook =/g" "$file" 2>/dev/null || true
            
            changes_made=true
            echo "    Removed: $hook from $file"
        fi
    done
    
    if [ "$changes_made" = true ]; then
        # Clean up empty lines
        sed -i '/^[[:space:]]*$/d' "$file" 2>/dev/null || true
        # Clean up duplicate blank lines
        sed -i '/^$/N;/^\n$/d' "$file" 2>/dev/null || true
    fi
    
    return 0
}

remove_susfs_files() {
    print_step "Removing Susfs files..."
    
    for file in "${SUSFS_FILES[@]}"; do
        if [ -f "$file" ]; then
            rm -f "$file"
            echo "  Removed: $file"
        fi
    done
    
    print_success "Susfs files removed."
    echo ""
}

remove_kernelsu_directory() {
    print_step "Removing drivers/kernelsu directory..."
    
    if [ -d "drivers/kernelsu" ]; then
        rm -rf "drivers/kernelsu"
        echo "  Removed: drivers/kernelsu/"
        print_success "KernelSU directory removed."
    else
        print_info "No drivers/kernelsu directory found."
    fi
    echo ""
}

cleanup_hooks() {
    print_step "Cleaning up incompatible hooks..."
    echo ""
    
    for file in "${KSU_HOOK_FILES[@]}"; do
        if [ -f "$file" ]; then
            local had_hooks=false
            
            for hook in "${INCOMPATIBLE_HOOKS[@]}"; do
                if grep -q "$hook" "$file" 2>/dev/null; then
                    had_hooks=true
                    break
                fi
            done
            
            if [ "$had_hooks" = true ]; then
                echo "  Processing: $file"
                remove_incompatible_hooks_from_file "$file"
            fi
        fi
    done
    
    print_success "Incompatible hooks removed."
    echo ""
}

remove_config_ksu() {
    print_step "Removing CONFIG_KSU from defconfigs..."
    
    local defconfigs=$(find . -name "*defconfig*" -type f 2>/dev/null)
    
    for file in $defconfigs; do
        if grep -q "CONFIG_KSU" "$file" 2>/dev/null; then
            sed -i 's/CONFIG_KSU=y/# CONFIG_KSU is not set/g' "$file" 2>/dev/null || true
            sed -i '/CONFIG_KSU/d' "$file" 2>/dev/null || true
            echo "  Cleaned: $file"
        fi
    done
    
    print_success "CONFIG_KSU removed from defconfigs."
    echo ""
}

verify_cleanup() {
    print_step "Verifying cleanup..."
    echo ""
    
    local issues=0
    
    # Check for remaining incompatible hooks
    for file in "${KSU_HOOK_FILES[@]}"; do
        if [ -f "$file" ]; then
            for hook in "${INCOMPATIBLE_HOOKS[@]}"; do
                if grep -q "$hook" "$file" 2>/dev/null; then
                    print_warning "Still found: $hook in $file"
                    ((issues++))
                fi
            done
        fi
    done
    
    # Check for remaining Susfs files
    for file in "${SUSFS_FILES[@]}"; do
        if [ -f "$file" ]; then
            print_warning "Still exists: $file"
            ((issues++))
        fi
    done
    
    # Check for remaining KSU directory
    if [ -d "drivers/kernelsu" ]; then
        print_warning "Still exists: drivers/kernelsu/"
        ((issues++))
    fi
    
    echo ""
    
    if [ $issues -eq 0 ]; then
        print_success "Verification passed - all old KSU cleaned!"
        return 0
    else
        print_warning "Verification found $issues remaining items."
        print_info "You may need to manually remove these or run this script again."
        return 1
    fi
}

show_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}========================================${NC}"
    echo -e "${BOLD}${GREEN}  Cleanup Complete!${NC}"
    echo -e "${BOLD}${GREEN}========================================${NC}"
    echo ""
    echo "Backup location: $BACKUP_DIR"
    echo ""
    echo "Next steps:"
    echo "  1. Review changes: git diff"
    echo "  2. Test build: make defconfig && make -j\$(nproc)"
    echo "  3. If issues: restore from $BACKUP_DIR"
    echo ""
}

# Main execution
main() {
    print_header
    
    # Check if running in kernel source directory
    if [ ! -f "Makefile" ]; then
        print_warning "Khong tim thay Makefile - co the khong phai kernel source."
        confirm "Van tiep tuc?"
    fi
    
    echo "Kernel source: $(pwd)"
    echo ""
    
    # Show what will be cleaned
    echo -e "${YELLOW}The following will be cleaned:${NC}"
    echo "  - Old/incompatible KSU hooks from kernel files"
    echo "  - fs/susfs.c, include/linux/susfs.h, include/linux/susfs_def.h"
    echo "  - drivers/kernelsu/ directory"
    echo "  - CONFIG_KSU from defconfigs"
    echo ""
    
    confirm "Prepare to clean old KSU?"
    
    # Create backup first
    backup_current_state
    
    # Perform cleanup
    cleanup_hooks
    remove_susfs_files
    remove_kernelsu_directory
    remove_config_ksu
    
    # Verify
    verify_cleanup
    
    # Show summary
    show_summary
    
    exit 0
}

# Run
main "$@"
