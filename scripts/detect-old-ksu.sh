#!/bin/bash
# detect-old-ksu.sh - Tìm và phân tích KSU hooks cũ trong kernel source
# Version: 2.0.0
#
# Version-agnostic KSU detection. Không phụ thuộc git history (kháng shallow
# clone _depth 1), dựa trên static map 2 tầng chuẩn nguồn:
#   TIER_LEGACY  : ksu_handle_* đặt inline trong host files (guard CONFIG_KSU)
#   TIER_CURRENT : dispatcher ksu_hook_* trong syscall_hook_manager.c + 3 LSM
#                  symbols (patch động theo security_hook_heads)
# Legacy compat còn tồn đọng trong host files được đánh dấu COMPAT.

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# ============ STATIC MAP (chuẩn nguồn KernelSU) ============
# Tier 1: LEGACY INLINE — ksu_handle_* đặt thẳng trong host files.
# Mapping file→symbols (dùng kể cả khi thiếu git history).
declare -A TIER_LEGACY_FILE
TIER_LEGACY_FILE["fs/exec.c"]="ksu_handle_execveat ksu_handle_execve"
TIER_LEGACY_FILE["fs/open.c"]="ksu_handle_faccessat"
TIER_LEGACY_FILE["fs/stat.c"]="ksu_handle_stat ksu_handle_newfstatat ksu_handle_fstat64_ret"
TIER_LEGACY_FILE["kernel/sys.c"]="ksu_handle_setresuid ksu_handle_sys_reboot"
TIER_LEGACY_FILE["fs/read_write.c"]="ksu_handle_sys_read"
TIER_LEGACY_FILE["kernel/reboot.c"]="ksu_handle_sys_reboot"
TIER_LEGACY_FILE["drivers/input/input.c"]="ksu_handle_input_handle_event"

# Tier 2: CURRENT DISPATCHER — đăng ký runtime trong syscall_hook_manager.c
TIER_CURRENT_DISPATCHER_SYMBOLS=(
    "ksu_hook_setresuid"
    "ksu_hook_execve"
    "ksu_hook_newfstatat"
    "ksu_hook_faccessat"
)
TIER_CURRENT_DISPATCHER_FILE="kernel/syscall_hook_manager.c"

# Tier 2: CURRENT LSM — patch động theo symbol security_hook_heads, không nằm
# host file cố định. Chỉ cần grep symbol trong kernel source.
TIER_CURRENT_LSM_SYMBOLS=(
    "ksu_handle_path_truncate"
    "ksu_handle_task_alloc"
    "ksu_handle_task_free"
)

# Legacy compat tồn đọng trong host files — đánh dấu COMPAT, cần dọn.
COMPAT_OLD_HOOKS=(
    "ksu_vfs_read_hook"
    "ksu_input_hook"
    "ksu_execveat_hook"
    "ksu_init_rc_hook"
    "ksu_vfs_write_hook"
    "ksu_stat_hook"
    "ksu_setresuid_hook"
    "ksu_reboot_hook"
    "ksu_faccessat_hook"
    "ksu_handle_rename"
)

# KSU commit message patterns
KSU_COMMIT_PATTERNS=(ksu kernelsu KernelSU susfs)

# Output files
REPORT_FILE="ksu_old_hooks_report.txt"

print_header() {
    echo -e "${BOLD}${BLUE}========================================${NC}"
    echo -e "${BOLD}${BLUE}  KSU Old Hooks Detector v2.0${NC}"
    echo -e "${BOLD}${BLUE}========================================${NC}"
    echo ""
}

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# Probe shallow repo: trả 0 nếu shallow, 1 nếu full/không có git.
git_is_shallow() {
    if [ ! -d ".git" ]; then
        return 1
    fi
    if git rev-parse --is-shallow-repository 2>/dev/null | grep -q "true"; then
        return 0
    fi
    # Fallback: đếm commit, <10 thường là shallow/anomaly
    if [ "$(git rev-list --count --all 2>/dev/null || echo 0)" -lt 10 ]; then
        return 0
    fi
    return 1
}

# Quét static map 2 tầng — hoạt động độc lập git history.
scan_static_hooks() {
    print_info "Scanning static KSU hooks (version-agnostic)..."

    local found_any=false
    local legacy_found=false
    local current_found=false
    local compat_found=false
    local disp_file_mod=false

    # ---- TIER_LEGACY: inline ksu_handle_* trong host files ----
    for file in "${!TIER_LEGACY_FILE[@]}"; do
        [ -f "$file" ] || continue
        local symbols=(${TIER_LEGACY_FILE[$file]})
        local file_found=false
        local hook_details=""
        for sym in "${symbols[@]}"; do
            if grep -qE "\b${sym}\b" "$file" 2>/dev/null; then
                file_found=true
                legacy_found=true
                hook_details+="  - ${GREEN}LEGACY INLINE: $sym${NC}\n"
            fi
        done
        # Hiện diện ksu_handle_* tổng quát (symbol lạ chưa map)
        if grep -q "ksu_handle_" "$file" 2>/dev/null; then
            file_found=true
            legacy_found=true
            hook_details+="  - ${GREEN}LEGACY INLINE: ksu_handle_* (khác)${NC}\n"
        fi
        if [ "$file_found" = true ]; then
            found_any=true
            echo -e "File: ${BOLD}$file${NC}"
            echo -e "$hook_details"
            if git_is_shallow; then
                # Vẫn thử git log nếu có (full clone sẽ chạy), không fail nếu thiếu
                [ -d ".git" ] && git log --oneline -3 --all -- "$file" 2>/dev/null | head -3 | sed 's/^/  [-SHALLOW] commit: /' || true
            fi
            echo ""
        fi
    done

    # ---- TIER_CURRENT: dispatcher ----
    if [ -f "$TIER_CURRENT_DISPATCHER_FILE" ]; then
        local found_disp=0
        for sym in "${TIER_CURRENT_DISPATCHER_SYMBOLS[@]}"; do
            grep -q "\b${sym}\b" "$TIER_CURRENT_DISPATCHER_FILE" 2>/dev/null && { ((found_disp++)); }
        done
        if [ "$found_disp" -gt 0 ]; then
            disp_file_mod=true
            current_found=true
            found_any=true
            echo -e "File: ${BOLD}$TIER_CURRENT_DISPATCHER_FILE${NC}"
            echo -e "  - ${GREEN}CURRENT DISPATCHER: $found_disp/${#TIER_CURRENT_DISPATCHER_SYMBOLS[@]} ksu_hook_* symbols${NC}"
            echo ""
        fi
    fi

    # ---- TIER_CURRENT: LSM (patch động) ----
    local lsm_found=0
    for sym in "${TIER_CURRENT_LSM_SYMBOLS[@]}"; do
        if grep -rq "\b${sym}\b" --include="*.c" --include="*.h" . 2>/dev/null; then
            ((lsm_found++))
        fi
    done
    if [ "$lsm_found" -gt 0 ]; then
        current_found=true
        found_any=true
        echo -e "File: ${BOLD}(LSM dynamic)${NC}"
        echo -e "  - ${GREEN}CURRENT LSM: $lsm_found/${#TIER_CURRENT_LSM_SYMBOLS[@]} ksu_handle_* LSM symbols${NC}"
        echo ""
    fi

    # ---- COMPAT: old inline hooks tồn đọng ----
    for file in "${!TIER_LEGACY_FILE[@]}"; do
        [ -f "$file" ] || continue
        local compat_details=""
        local compat_in_file=false
        for hook in "${COMPAT_OLD_HOOKS[@]}"; do
            if grep -q "\b${hook}\b" "$file" 2>/dev/null; then
                compat_in_file=true
                compat_found=true
                found_any=true
                compat_details+="  - ${RED}COMPAT: $hook${NC}\n"
            fi
        done
        if [ "$compat_in_file" = true ]; then
            echo -e "File: ${BOLD}$file${NC} (compat residue)"
            echo -e "$compat_details"
            echo ""
        fi
    done

    # ---- ORPHAN SCAN: quét toàn tree để bắt hook ở file ngoài map cố định ---
    # (vd fs/namei.c, fs/vfs-*, kernel/cred.c, security/security.c...) — phiên
    # bản KSU cũ đặt hook ở nhiều nơi lạ, không phụ thuộc git history biết được.
    local orphan_found=false
    local orphan_map=()
    # Chỉ quét các thư mục kernel thường chứa hook (tránh quét toàn tree chậm)
    local scan_dirs=(fs kernel drivers/input security drivers/kernelsu/kernel)
    for sym in "${COMPAT_OLD_HOOKS[@]}"; do
        while IFS= read -r hit; do
            [ -z "$hit" ] && continue
            orphan_map+=("$hit")
        done < <(grep -rlw --include="*.c" --include="*.h" "$sym" "${scan_dirs[@]}" 2>/dev/null)
    done
    # Lọc trùng & bỏ file đã nằm trong map chính (đã in ở trên)
    local seen=()
    for hit in "${orphan_map[@]}"; do
        local f="${hit#./}"
        # Bỏ qua file vốn đã scan trong TIER_LEGACY (tránh in trùng)
        if [ -n "${TIER_LEGACY_FILE[$f]:-}" ]; then
            continue
        fi
        local dup=false
        for s in "${seen[@]}"; do
            [ "$s" = "$f" ] && dup=true
        done
        [ "$dup" = true ] && continue
        seen+=("$f")
        orphan_found=true
        found_any=true
        compat_found=true
        echo -e "File: ${BOLD}$f${NC} (orphan KSU residue - outside standard map)"
        echo ""
    done
    if [ "$orphan_found" = true ]; then
        print_warning "Phat hien KSU residue o file nam ngoai map tieu chuan - can cleanup."
        echo ""
    fi

    if [ "$found_any" = false ]; then
        print_success "Khong tim thay KSU hooks (legacy/current/compat)."
    fi

    # Kết luận tier
    echo ""
    if [ "$compat_found" = true ]; then
        print_warning "Legacy COMPAT còn tồn đọng -> can cleanup (ksu-cleanup-helper.sh)."
    elif [ "$legacy_found" = true ]; then
        print_info "Integration kiểu LEGACY INLINE (ksu_handle_* trong host files)."
    elif [ "$current_found" = true ]; then
        print_info "Integration kiểu CURRENT (dispatcher + LSM dynamic)."
    fi
    echo ""

    local legend=0
    { [ "$compat_found" = true ] && legend=1; }
    return $legend
}

# Quét git history cho KSU (giữ nguyên, chống shallow).
scan_git_history_for_ksu() {
    print_info "Scanning git history for KSU-related commits..."

    if [ -d ".git" ] && git_is_shallow; then
        print_warning "[SHALLOW] bỏ qua git history (repo depth 1)."
        print_info "Chay 'git fetch --unshallow' neu muon scan history sau."
        echo ""
        return 0
    fi

    if [ ! -d ".git" ]; then
        print_warning "Khong co .git - skip git history scan."
        echo ""
        return 0
    fi

    local grep_args=()
    for p in "${KSU_COMMIT_PATTERNS[@]}"; do
        grep_args+=(--grep="$p")
    done

    local ksu_commits=$(git log --all --oneline "${grep_args[@]}" -i 2>/dev/null | head -20)

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
            echo -e "  - ${RED}$file${NC} (exists - maybe old version)"
            if grep -q "SUSFS_VERSION" "$file" 2>/dev/null; then
                echo "    $(grep "SUSFS_VERSION" "$file" | head -1)"
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
        if [ -f "drivers/kernelsu/version.h" ]; then
            local v=$(grep "Kernelsu_VERSION" "drivers/kernelsu/version.h" 2>/dev/null | head -1)
            [ -n "$v" ] && echo "    $v"
        elif [ -f "drivers/kernelsu/version" ]; then
            echo "    $(cat drivers/kernelsu/version 2>/dev/null)"
        fi
        echo ""
        print_warning "Existing KernelSU found - maybe conflict with new integration."
        echo ""
        return 1
    else
        print_success "No existing KernelSU directory found."
        echo ""
        return 0
    fi
}

# Définit KSU_VERSION + kiểu config (manual / compat).
read_ksu_version() {
    KSU_VERSION=""
    if [ -f "drivers/kernelsu/version.h" ]; then
        KSU_VERSION=$(grep -oP 'Kernelsu_VERSION\s+\K[0-9.]+' drivers/kernelsu/version.h 2>/dev/null || echo "")
    fi
    if [ -z "$KSU_VERSION" ] && [ -f "drivers/kernelsu/version" ]; then
        KSU_VERSION=$(cat drivers/kernelsu/version 2>/dev/null)
    fi
    echo "$KSU_VERSION"
}

check_config_ksu() {
    print_info "Checking KSU config (CONFIG_KSU / MANUAL / COMPAT + version)..."
    echo ""

    local found_config=false
    local is_manual=false
    local is_compat=false
    local kconfig_file=""
    local defconfig_files=$(find . -name "*defconfig*" -type f 2>/dev/null | head -10)

    for file in $defconfig_files; do
        if grep -q "CONFIG_KSU" "$file" 2>/dev/null; then
            found_config=true
            [ -z "$kconfig_file" ] && kconfig_file="$file"
            grep -q "CONFIG_KSU_MANUAL_HOOK" "$file" 2>/dev/null && is_manual=true
            grep -q "CONFIG_KSU_COMPAT" "$file" 2>/dev/null && is_compat=true
        fi
    done

    if [ "$found_config" = true ]; then
        echo -e "  - ${YELLOW}$kconfig_file${NC}: CONFIG_KSU found"
        local version=$(read_ksu_version)
        if [ -n "$version" ]; then
            echo "    KSU_VERSION: $version"
        else
            print_warning "    Khong doc duoc KSU_VERSION (drivers/kernelsu)."
        fi
        if [ "$is_manual" = true ]; then
            print_info "    Integration: KSU_MANUAL_HOOK (legacy inline/compat)"
        elif [ "$is_compat" = true ]; then
            print_info "    Integration: KSU_COMPAT"
        else
            print_info "    Integration: KSU auto (dispatcher/LSM)"
        fi
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

    # COMPAT residue -> cleanup (scan toàn tree, bắt cả file ngoài map chuẩn)
    local scan_targets=()
    local summary_dirs=(fs kernel drivers/input security)
    for hook in "${COMPAT_OLD_HOOKS[@]}"; do
        while IFS= read -r hit; do
            [ -z "$hit" ] && continue
            scan_targets+=("${hit#./}")
        done < <(grep -rlw --include="*.c" --include="*.h" "$hook" "${summary_dirs[@]}" 2>/dev/null)
    done

    for file in "${scan_targets[@]}"; do
        if [ -f "$file" ]; then
            for hook in "${COMPAT_OLD_HOOKS[@]}"; do
                if grep -q "\b${hook}\b" "$file" 2>/dev/null; then
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

main() {
    print_header

    if [ ! -f "Makefile" ]; then
        print_warning "Khong tim thay Makefile - co the khong phai kernel source."
        read -p "Van tiep tuc? (y/n): " confirm
        [ "$confirm" != "y" ] && exit 0
    fi

    echo "Kernel source detected: $(pwd)"
    echo ""

    if git_is_shallow; then
        print_warning "[SHALLOW] Repo la shallow clone - detection dua tren static hooks/config."
        echo ""
    fi

    scan_kernelsu_dir || true
    scan_susfs_files || true
    scan_static_hooks || true
    scan_git_history_for_ksu || true
    check_config_ksu || true

    generate_summary
    exit $?
}

main "$@"