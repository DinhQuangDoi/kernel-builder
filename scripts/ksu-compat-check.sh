#!/bin/bash
# ksu-compat-check.sh - Run kernel_compat.mk checks to verify kernel compatibility
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
OUTPUT_JSON=false

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

print_header() {
    echo -e "${BOLD}${BLUE}========================================${NC}"
    echo -e "${BOLD}${BLUE}  KSU Kernel Compatibility Check${NC}"
    echo -e "${BOLD}${BLUE}========================================${NC}"
    echo ""
}

check_tools_exist() {
    if [ ! -f "${TOOLS_DIR}/kernel_compat.mk" ]; then
        print_warning "kernel_compat.mk not found in ${TOOLS_DIR}"
        print_info "Downloading from ReSukiSU..."
        
        mkdir -p "${TOOLS_DIR}"
        curl -sL "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/tools/kernel_compat.mk" \
            -o "${TOOLS_DIR}/kernel_compat.mk" 2>/dev/null || {
            print_error "Failed to download kernel_compat.mk"
            return 1
        }
    fi
    
    return 0
}

run_selinux_checks() {
    echo -e "${BOLD}SELinux Compatibility:${NC}"
    echo ""
    
    local checks_passed=0
    local checks_total=0
    
    # current_sid(void)
    ((checks_total++))
    if grep -q "current_sid(void)" security/selinux/include/objsec.h 2>/dev/null; then
        print_success "current_sid found - KSU_COMPAT_HAS_CURRENT_SID"
        ((checks_passed++))
    else
        print_warning "current_sid not found"
    fi
    
    # selinux_state
    ((checks_total++))
    if grep -q "struct selinux_state " security/selinux/include/security.h 2>/dev/null; then
        print_success "selinux_state found - KSU_COMPAT_HAS_SELINUX_STATE"
        ((checks_passed++))
    else
        print_warning "selinux_state not found"
    fi
    
    # selinux_inode
    ((checks_total++))
    if grep -q "inode_security_struct\s\+\*selinux_inode" security/selinux/include/objsec.h 2>/dev/null; then
        print_success "selinux_inode found - KSU_OPTIONAL_SELINUX_INODE"
        ((checks_passed++))
    else
        print_warning "selinux_inode not found"
    fi
    
    # selinux_cred
    ((checks_total++))
    if grep -q "task_security_struct\s\+\*selinux_cred" security/selinux/include/objsec.h 2>/dev/null; then
        print_success "selinux_cred found - KSU_OPTIONAL_SELINUX_CRED"
        ((checks_passed++))
    else
        print_warning "selinux_cred not found"
    fi
    
    # policy_mutex (kernel 5.10+)
    ((checks_total++))
    if grep -q "policy_mutex" security/selinux/include/security.h 2>/dev/null; then
        print_success "policy_mutex found - KSU_COMPAT_HAS_POLICY_MUTEX"
        ((checks_passed++))
    else
        print_warning "policy_mutex not found (kernel < 5.10)"
    fi
    
    echo ""
    return $checks_passed
}

run_samsung_checks() {
    echo -e "${BOLD}Samsung Compatibility:${NC}"
    echo ""
    
    local checks_passed=0
    local checks_total=0
    
    # CONFIG_KDP_CRED
    ((checks_total++))
    if grep -q "CONFIG_KDP_CRED" kernel/cred.c 2>/dev/null; then
        print_success "CONFIG_KDP_CRED found - SAMSUNG_UH_DRIVER_EXIST"
        ((checks_passed++))
    else
        print_warning "CONFIG_KDP_CRED not found"
    fi
    
    # SEC_SELINUX_PORTING_COMMON
    ((checks_total++))
    if grep -q "SEC_SELINUX_PORTING_COMMON" security/selinux/avc.c 2>/dev/null; then
        print_success "SEC_SELINUX_PORTING_COMMON found - SAMSUNG_SELINUX_PORTING"
        ((checks_passed++))
    else
        print_warning "SEC_SELINUX_PORTING_COMMON not found"
    fi
    
    echo ""
    return $checks_passed
}

run_huawei_checks() {
    echo -e "${BOLD}Huawei Compatibility:${NC}"
    echo ""
    
    local checks_passed=0
    local checks_total=0
    
    # CONFIG_HKIP_SELINUX_PROT
    ((checks_total++))
    if grep -q "CONFIG_HKIP_SELINUX_PROT" security/selinux/ss/ebitmap.h 2>/dev/null; then
        print_success "CONFIG_HKIP_SELINUX_PROT found - KSU_COMPAT_IS_HISI_HM2"
        ((checks_passed++))
    else
        print_warning "CONFIG_HKIP_SELINUX_PROT not found"
    fi
    
    echo ""
    return $checks_passed
}

run_kernel_feature_checks() {
    echo -e "${BOLD}Kernel Feature Compatibility:${NC}"
    echo ""
    
    local checks_passed=0
    local checks_total=0
    
    # strncpy_from_user_nofault
    ((checks_total++))
    if grep -q "strncpy_from_user_nofault" include/linux/uaccess.h 2>/dev/null; then
        print_success "strncpy_from_user_nofault found - KSU_OPTIONAL_STRNCPY"
        ((checks_passed++))
    else
        print_warning "strncpy_from_user_nofault not found"
    fi
    
    # kernel_read
    ((checks_total++))
    if grep -q "ssize_t kernel_read" fs/read_write.c 2>/dev/null; then
        print_success "kernel_read found - KSU_OPTIONAL_KERNEL_READ"
        ((checks_passed++))
    else
        print_warning "kernel_read not found"
    fi
    
    # kernel_write with const void
    ((checks_total++))
    if grep "ssize_t kernel_write" fs/read_write.c 2>/dev/null | grep -q "const void"; then
        print_success "kernel_write (const void) found - KSU_OPTIONAL_KERNEL_WRITE"
        ((checks_passed++))
    else
        print_warning "kernel_write with const void not found"
    fi
    
    # path_umount
    ((checks_total++))
    if grep -q "int\s\+path_umount" fs/namespace.c 2>/dev/null; then
        print_success "path_umount found - KSU_HAS_PATH_UMOUNT"
        ((checks_passed++))
    else
        print_warning "path_umount not found"
    fi
    
    # anon_inode_getfd_secure
    ((checks_total++))
    if grep -q "anon_inode_getfd_secure" fs/anon_inodes.c 2>/dev/null; then
        print_success "anon_inode_getfd_secure found - KSU_HAS_GETFD_SECURE"
        ((checks_passed++))
    else
        print_warning "anon_inode_getfd_secure not found"
    fi
    
    # anon_inode_create_getfd (6.8+)
    ((checks_total++))
    if grep -q "anon_inode_create_getfd" fs/anon_inodes.c 2>/dev/null; then
        print_success "anon_inode_create_getfd found - KSU_HAS_ANON_INODE_CREATE_FD"
        ((checks_passed++))
    else
        print_warning "anon_inode_create_getfd not found"
    fi
    
    # file_inode()
    ((checks_total++))
    if grep -q "static inline struct inode \*file_inode" include/linux/fs.h 2>/dev/null; then
        print_success "file_inode() found - KSU_UL_HAS_FILE_INODE"
        ((checks_passed++))
    else
        print_warning "file_inode() not found"
    fi
    
    # ns_get_path
    ((checks_total++))
    if grep -q "ns_get_path" fs/nsfs.c 2>/dev/null; then
        print_success "ns_get_path found - KSU_COMPAT_HAS_NS_GET_PATH"
        ((checks_passed++))
    else
        print_warning "ns_get_path not found"
    fi
    
    # inode_lock
    ((checks_total++))
    if grep -q "inode_lock.struct inode" include/linux/fs.h 2>/dev/null; then
        print_success "inode_lock found - KSU_HAS_INODE_LOCK_UNLOCK"
        ((checks_passed++))
    else
        print_warning "inode_lock not found"
    fi
    
    echo ""
    return $checks_passed
}

run_android_checks() {
    echo -e "${BOLD}Android SPEC Compatibility:${NC}"
    echo ""
    
    local checks_passed=0
    local checks_total=0
    
    # POLICYDB_CONFIG_ANDROID_NETLINK_ROUTE
    ((checks_total++))
    if grep -q "POLICYDB_CONFIG_ANDROID_NETLINK_ROUTE" security/selinux/ss/policydb.h 2>/dev/null; then
        print_success "POLICYDB_CONFIG_ANDROID_NETLINK_ROUTE found"
        ((checks_passed++))
    else
        print_warning "POLICYDB_CONFIG_ANDROID_NETLINK_ROUTE not found"
    fi
    
    # POLICYDB_CONFIG_ANDROID_NETLINK_GETNEIGH
    ((checks_total++))
    if grep -q "POLICYDB_CONFIG_ANDROID_NETLINK_GETNEIGH" security/selinux/ss/policydb.h 2>/dev/null; then
        print_success "POLICYDB_CONFIG_ANDROID_NETLINK_GETNEIGH found"
        ((checks_passed++))
    else
        print_warning "POLICYDB_CONFIG_ANDROID_NETLINK_GETNEIGH not found"
    fi
    
    # flex_array in policydb
    ((checks_total++))
    if grep -q "flex_array" security/selinux/ss/policydb.h 2>/dev/null; then
        print_success "Modern selinux policydb found - KSU_COMPAT_HAS_MODERN_POLICYDB"
        ((checks_passed++))
    else
        print_warning "Modern selinux policydb not found"
    fi
    
    echo ""
    return $checks_passed
}

run_header_checks() {
    echo -e "${BOLD}Header File Checks:${NC}"
    echo ""
    
    local checks_passed=0
    local checks_total=0
    
    # minmax.h
    ((checks_total++))
    if [ -f "include/linux/minmax.h" ]; then
        print_success "minmax.h found - KSU_COMPAT_HAS_MINMAX_H"
        ((checks_passed++))
    else
        print_warning "minmax.h not found (kernel < 5.10)"
    fi
    
    # overflow.h
    ((checks_total++))
    if [ -f "include/linux/overflow.h" ]; then
        print_success "overflow.h found - KSU_COMPAT_HAS_OVERFLOW_H"
        ((checks_passed++))
    else
        print_warning "overflow.h not found (kernel < 4.18)"
    fi
    
    # proc_ns.h
    ((checks_total++))
    if [ -f "include/linux/proc_ns.h" ]; then
        print_success "proc_ns.h found - KSU_HAS_MODERN_PROC_NS"
        ((checks_passed++))
    else
        print_warning "proc_ns.h not found (kernel < 3.14)"
    fi
    
    echo ""
    return $checks_passed
}

generate_summary() {
    local total_passed=$1
    local total_checks=$2
    
    echo -e "${BOLD}${BLUE}========================================${NC}"
    echo -e "${BOLD}${BLUE}  Compatibility Summary${NC}"
    echo -e "${BOLD}${BLUE}========================================${NC}"
    echo ""
    echo "Checks Passed: ${total_passed}/${total_checks}"
    
    local percentage=$((total_passed * 100 / total_checks))
    
    if [ $percentage -ge 80 ]; then
        echo -e "Status: ${GREEN}GOOD${NC} (${percentage}%)"
        echo ""
        echo "The kernel appears to be compatible with KSU."
        return 0
    elif [ $percentage -ge 60 ]; then
        echo -e "Status: ${YELLOW}PARTIAL${NC} (${percentage}%)"
        echo ""
        echo "Some features may need manual adaptation."
        return 1
    else
        echo -e "Status: ${RED}POOR${NC} (${percentage}%)"
        echo ""
        echo "The kernel may have compatibility issues."
        return 2
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

main() {
    print_header
    
    # Check if in kernel source
    if [ ! -f "Makefile" ]; then
        print_error "Makefile not found. Run in kernel source directory."
        exit 1
    fi
    
    # Check tools
    check_tools_exist || exit 1
    
    local total_passed=0
    local total_checks=0
    
    # Run all checks (each function prints results and returns the passed count)
    local selinux_passed=0
    run_selinux_checks || selinux_passed=$?
    total_passed=$((total_passed + selinux_passed))
    total_checks=$((total_checks + 5))
    
    local samsung_passed=0
    run_samsung_checks || samsung_passed=$?
    total_passed=$((total_passed + samsung_passed))
    total_checks=$((total_checks + 2))
    
    local huawei_passed=0
    run_huawei_checks || huawei_passed=$?
    total_passed=$((total_passed + huawei_passed))
    total_checks=$((total_checks + 1))
    
    local feature_passed=0
    run_kernel_feature_checks || feature_passed=$?
    total_passed=$((total_passed + feature_passed))
    total_checks=$((total_checks + 9))
    
    local android_passed=0
    run_android_checks || android_passed=$?
    total_passed=$((total_passed + android_passed))
    total_checks=$((total_checks + 3))
    
    local header_passed=0
    run_header_checks || header_passed=$?
    total_passed=$((total_passed + header_passed))
    total_checks=$((total_checks + 3))
    
    # Generate summary
    generate_summary $total_passed $total_checks
    
    exit $?
}

main "$@"
