# Kernel Builder Skill - ReSukiSU Integration + CI/CD

## Mô tả

Skill này giúp tự động hoá việc tích hợp ReSukiSU (KernelSU) vào kernel non-GKI và thiết lập GitHub Actions CI/CD.

## Cấu trúc

```
kernel-builder/
├── scripts/
│   ├── detect-old-ksu.sh      # Phase 1: Tìm KSU hooks cũ
│   ├── ksu-cleanup-helper.sh  # Phase 1: Loại bỏ KSU cũ an toàn
│   ├── detect-kernel.sh       # Detect kernel version
│   ├── detect-toolchain.sh     # Detect Clang/GCC
│   ├── detect-ksu.sh          # Check KSU/Susfs status
│   ├── ksu-compat-check.sh     # Phase 3: Check kernel compatibility
│   ├── ksu-hook-verify.sh      # Phase 3: Verify hooks installed
│   ├── check-symbols.sh        # Phase 3: Verify symbols
│   └── generate-workflow.py    # Phase 4: Generate CI workflow
├── tools/                     # ReSukiSU kernel tools
│   ├── kernel_compat.mk
│   ├── inline_hook_check.mk
│   ├── manual_hook_check.mk
│   ├── check_symbol.c
│   └── ...
└── skill/
    └── kernel-build-skill.md   # This file
```

## Workflow

```
┌────────────────────────────────────────────────────────────────────┐
│  PHASE 1: CLEAN OLD KSU HOOKS (Pre-integration)                 │
│  ├── ./detect-old-ksu.sh - Scan old KSU hooks                   │
│  └── ./ksu-cleanup-helper.sh - Safely remove ONLY KSU hooks     │
│                         ↓                                         │
│  PHASE 2: KSU INTEGRATION                                         │
│  ├── Add ReSukiSU symlink                                       │
│  ├── Apply susfs patches                                        │
│  └── Apply inline hooks                                         │
│                         ↓                                         │
│  PHASE 3: HOOK VERIFICATION                                      │
│  ├── ./ksu-compat-check.sh - Kernel compatibility               │
│  ├── ./ksu-hook-verify.sh - Hook verification                   │
│  └── ./check-symbols.sh - Symbol verification                    │
│                         ↓                                         │
│  PHASE 4: WORKFLOW GENERATION                                    │
│  └── python3 ./generate-workflow.py --detect                    │
└────────────────────────────────────────────────────────────────────┘
```

---

## ⚠️ Nhắc nhở bắt buộc cho Agent

> Các quy tắc này rất quan trọng để tránh hỏng repo kernel. Đọc kỹ trước khi commit.

### 1. KHÔNG bao giờ commit `kernel-builder/` vào kernel repo
- `kernel-builder/` là một git repo **riêng** (`https://github.com/DinhQuangDoi/kernel-builder.git`).
- Không `git add kernel-builder/`, không `git add -A .` (sẽ vô tình thêm nó như embedded repo / gitlink `160000`).
- Nếu lỡ staged, bỏ: `git rm -r --cached -f kernel-builder`.
- Tương tự **không commit** các thư mục/repo phụ lạ (vd `gtest/` — untracked, không liên quan).

### 2. Stage có chọn lọc, KHÔNG dùng `git add -A`
- Chỉ `git add` đích danh các file integrate:
  - `arch/arm64/configs/op8_defconfig`
  - `drivers/Kconfig`, `drivers/Makefile`, `drivers/input/input.c`
  - `fs/` (susfs.c, exec.c, namei.c, namespace.c, ...)
  - `include/linux/susfs.h`, `include/linux/susfs_def.h`, `include/linux/seccomp.h`
  - `kernel/`, `mm/`, `security/selinux/`
  - `KernelSU` (gitlink `160000`), `drivers/kernelsu` (symlink `120000`), `.gitmodules`, `fs/susfs.c`
  - `.github/workflows/*.yml`
- Sau stage, chạy `git diff --cached --name-only` và kiểm tra **không** có `kernel-builder/` hay `gtest/`.

### 3. File `.github/`, `.gitmodules`, `.*` bị `.gitignore` chặn
- `.gitignore` có rule `.*` -> `.github/` và `.gitmodules` **không add thường được**.
- Phải dùng `git add -f .github/workflows/kernel-build.yml` và `git add -f .gitmodules`.
- KHÔNG sửa `.gitignore` để bypass; dùng `-f` (mẫu nhánh cũ dùng force add).

### 4. Đăng ký submodule KernelSU trong `.gitmodules`
- Thiếu `.gitmodules` thì GitHub Actions (`submodules: recursive`) không fetch được ReSukiSU.
- Nội dung:
  ```
  [submodule "KernelSU"]
  	path = KernelSU
  	url = https://github.com/ReSukiSU/ReSukiSU
  ```

### 5. Module signing phải TẮT cho driver `.ko` không ký
- Đảm bảo `op8_defconfig` có `# CONFIG_MODULE_SIG is not set` (đã bỏ `CONFIG_MODULE_SIG_FORCE`, `_ALL`, `_KEY`).
- Nếu đang còn `CONFIG_MODULE_SIG_FORCE=y` -> driver không ký sẽ không load được.
- `CONFIG_MODVERSIONS=y` là chuẩn; chỉ tắt khi `insmod` báo lỗi symbol/CRC không khớp.

### 6. Kiểm tra submodule trước khi commit
- `git ls-files -s | grep -E "160000|120000"` để xác nhận:
  - `KernelSU` = mode `160000` (gitlink)
  - `drivers/kernelsu` = mode `120000` (symlink)

### 7. Đảm bảo không còn file patch dư thừa
- Trước khi commit: `find . -name "*.rej" -o -name "*.orig"` (ngoài kernel-builder) -> xoá.
- Hooks apply lỗi 1 hunk (vd `fs/namespace.c`) thì sửa tay, đừng commit `.rej`/`.orig`.

### 8. Workflow CI dùng ccache để rebuild nhanh (26p → ~9p)
- Workflow tham chiếu: `JackA1ltman/NonGKI_Kernel_Build_2nd` (op8: `build-oneplus-8-series-oos13-a13-xtd.yml`).
- Cách tối ưu đã áp dụng:
  1. Cài `ccache` trong "Install dependencies".
  2. Env: `CCACHE_COMPILERCHECK`, `CCACHE_NOHASHDIR=true`, `CCACHE_HARDLINK=true`.
  3. Trước build: `hendrikmuhs/ccache-action@v1.2.22` (key `build-kernel-${{DEVICE_CODENAME}}-${{TOOLCHAIN_TYPE}}`, `max-size: 2G`) — persist cache giữa các run.
  4. Build dùng `CC="ccache clang"` (bọc compiler) + `-j$(nproc --all)`.
  5. Đọc hiệu quả: step "ccache stats" (Hits/Misses/Hit rate).
- Lần build đầu tiên vẫn ~26p (chưa có cache); từ lần sau gần như full cache-hit, chỉ compile phần thay đổi (~9p).
- Khi `kernelsu` source thay đổi, ccache-key đổi theo `DEVICE_CODENAME`+`TOOLCHAIN_TYPE` mới để không dùng cache cũ sai.

---

## Sử dụng

### Cách 1: Chạy từng phase riêng biệt

#### Phase 1: Detect & Clean Old KSU

```bash
# Di chuyển vào thư mục kernel source
cd /path/to/kernel-source

# 1.1. Scan để tìm KSU hooks cũ
./kernel-builder/scripts/detect-old-ksu.sh

# 1.2. Nếu có KSU cũ, chạy cleanup
./kernel-builder/scripts/ksu-cleanup-helper.sh
```

#### Phase 2: KSU Integration

```bash
# 2.1. Detect environment
./kernel-builder/scripts/detect-kernel.sh
./kernel-builder/scripts/detect-toolchain.sh
./kernel-builder/scripts/detect-ksu.sh

# 2.2. Add ReSukiSU
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

# 2.3. Remove old Susfs (nếu có)
rm -f fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h

# 2.4. Apply susfs patch (chọn patch phù hợp với kernel version)
# Kernel 4.19:
curl -sL "https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/refs/heads/mainline/Patches/Patch/susfs_patch_to_4.19.patch" -o susfs_patch.patch
patch -p1 --force < susfs_patch.patch

# 2.5. Apply inline hooks
curl -sL "https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/refs/heads/mainline/Patches/susfs_inline_hook_patches.sh" -o susfs_inline.sh
bash susfs_inline.sh
```

#### Phase 3: Verify Hooks

```bash
# 3.1. Check kernel compatibility
./kernel-builder/scripts/ksu-compat-check.sh

# 3.2. Verify hooks installed
./kernel-builder/scripts/ksu-hook-verify.sh

# 3.3. Verify symbols (sau khi build)
./kernel-builder/scripts/check-symbols.sh drivers/kernelsu/ksud.ko vmlinux
```

#### Phase 4: Generate CI Workflow

```bash
# Interactive (khuyến nghị sau khi integrate xong): hỏi build local hay GitHub Actions,
# kiểm tra AK3 trong kernel tree, hỏi dùng AK3 có sẵn hay link AK3 khác
python3 ./kernel-builder/scripts/generate-workflow.py --interactive

# Generate workflow từ config
python3 ./kernel-builder/scripts/generate-workflow.py --config device-config.yml

# Hoặc auto-detect
python3 ./kernel-builder/scripts/generate-workflow.py --detect
```

Interactive mode flow:
1. Kiểm tra đã integrate ReSukiSU chưa (`drivers/kernelsu`) — chưa thì cảnh báo
2. Hiển thị các **CONFIG_KSU\*** đang bật trong defconfig
3. Hỏi build **local** hay **GitHub Actions workflow**
   - Local → in sẵn lệnh build (out-of-tree `O=out`)
4. GitHub Actions → hỏi AnyKernel3:
   - Có sẵn AK3 trong kernel tree → hỏi dùng nó hay AK3 khác
   - Không có sẵn → hỏi dùng mặc định osm0sis hay nhập git URL
5. Workflow tạo ra có **Build Summary**: list CONFIG_KSU\* enabled (từ `out/.config`)
   + link tải ReSukiSU Manager
6. **GitHub CLI (`gh`)**: generator tự kiểm tra `gh auth status`, hỏi đăng nhập
   nếu chưa, rồi hỏi commit+push workflow và kick+theo dõi build (`gh run watch`)

---

## Detect Scripts

### `detect-old-ksu.sh`

Scan kernel source để tìm KSU hooks cũ (incompatible).

**Tìm kiếm:**
- KSU hooks trong các file: `fs/exec.c`, `fs/open.c`, `fs/read_write.c`, etc.
- Susfs files cũ
- `drivers/kernelsu/` directory
- Git history cho KSU-related commits

**Output:**
```
========================================
  KSU Old Hooks Detector v1.0
========================================

[INFO] Scanning files for old KSU hooks...

File: fs/exec.c
  - INCOMPATIBLE: ksu_execveat_hook
File: kernel/sys.c
  - NEW STYLE: ksu_handle_* hooks

========================================
  SUMMARY
========================================

Old KSU detected - cleanup recommended before integration.

  1. Run: ./ksu-cleanup-helper.sh
  2. This will safely remove old KSU hooks
  3. Then proceed with new ReSukiSU integration
```

### `ksu-cleanup-helper.sh`

Safely remove old KSU hooks mà không ảnh hưởng đến code khác.

**Tính năng:**
- Backup trước khi xoá
- Chỉ xoá KSU-related code
- Revert incompatible hooks
- Verify sau khi clean

### `detect-kernel.sh`

Detect kernel version và thông tin.

**Output:**
```
========================================
  Kernel Version Detection
========================================

Full Version: 4.19.302
Family: 4.19+
Architecture: arm64
Defconfig: arch/arm64/configs/vendor/sweetin_defconfig
GKI Status: non_gki

Note: This kernel requires Non-GKI build method.
```

### `detect-toolchain.sh`

Detect toolchain (Clang/GCC) từ Makefile.

**Output:**
```
========================================
  Toolchain Detection Results
========================================

Primary Toolchain: clang
Binary: clang
Version: clang version 17.0.0
LLVM Utils: yes

Clang Detected: Yes
GCC Detected: No
```

### `detect-ksu.sh`

Check current KSU/Susfs status.

**Output:**
```
========================================
  KSU/Susfs Status Detection
========================================

KernelSU:
  Status: not_found
  Version: unknown

Susfs:
  Status: not_found
  Version: unknown

Hooks:
  New Style (ksu_handle_*): 0
  Incompatible (old style): 0

Recommendation: No KSU detected. Ready for new integration!
```

---

## Verification Scripts

### `ksu-compat-check.sh`

Run kernel compatibility checks dựa trên `kernel_compat.mk`.

**Checks:**
- SELinux compatibility
- Samsung/Huawei specific patches
- Kernel version specific features
- Android SPEC changes

### `ksu-hook-verify.sh`

Verify KSU hooks được install đúng cách.

**Kiểm tra:**
- Incompatible hooks (old style) - phải không có
- Required hooks (new style) - phải có
- Manual hook guards
- KSU directory
- Susfs integration

### `check-symbols.sh`

Verify symbols giữa `ksud.ko` và `vmlinux`.

```bash
./check-symbols.sh drivers/kernelsu/ksud.ko vmlinux
```

---

## Workflow Generator

### Device Config Example

```yaml
# device-config.yml
device:
  codename: "sweetin"
  defconfig: "vendor/sweetin_defconfig"
  arch: "arm64"

toolchain:
  type: "clang"
  clang_version: "17.0.6"
  gcc_prebuilt: "none"

kernel:
  version: "4.19"
  anykernel: true
  #anykernel_url: "https://github.com/custom/AnyKernel3.git"  # Custom AK3 repo
  #anykernel_in_tree: false  # Use an AK3 dir already in the kernel tree

ksu:
  integrated: true

upload:
  vmlinux: false           # Upload out/vmlinux? Mặc định FALSE (~200MB với DEBUG_INFO)

links:
  manager_url: "https://nightly.link/ReSukiSU/ReSukiSU/workflows/build-manager/main"

github:
  branch: "main"
```

> **Lưu ý:** Proton Clang đã ngừng phát hành. Mặc định dùng LLVM/Clang chính thức
> (`clang_version`), build out-of-tree qua `O=out` (tránh xung đột với
> `KBUILD_OUTPUT` hardcode trong kernel Makefile). Mọi step đều tự xử lý khi
> thiếu toolchain/AnyKernel3.
>
> **Lưu ý upload size:** `out/vmlinux` KHÔNG được upload mặc định (kernel
> `CONFIG_DEBUG_INFO=y` cho vmlinux ~200MB). Bật qua `upload.vmlinux: true`.
>
> **Build Summary:** sau khi workflow xong sẽ hiển thị các `CONFIG_KSU*` được bật
> (đọc từ `out/.config`) và link tải ReSukiSU Manager.

### Generate Command

```bash
# Interactive: hỏi build local hay GitHub Actions, AK3 có sẵn hay link khác
python3 scripts/generate-workflow.py --interactive

# Từ config file
python3 scripts/generate-workflow.py --config device-config.yml

# Auto-detect từ source
python3 scripts/generate-workflow.py --detect
```

---

## Hook Verification Details

### Incompatible Hooks (Old Style) - Phải được loại bỏ

| Hook | File | Description |
|------|------|-------------|
| `ksu_vfs_read_hook` | fs/read_write.c | Old vfs_read hook |
| `ksu_input_hook` | drivers/input/input.c | Old input hook |
| `ksu_execveat_hook` | fs/exec.c | Old execveat hook |
| `ksu_init_rc_hook` | fs/read_write.c, fs/stat.c | Old init_rc hook |

### Required Hooks (New Style) - Phải có sau integration

| Hook | File |
|------|------|
| `ksu_handle_setresuid` | kernel/sys.c |
| `ksu_handle_execveat` | fs/exec.c |
| `ksu_handle_faccessat` | fs/open.c |
| `ksu_handle_sys_read` | fs/read_write.c |
| `ksu_handle_stat` | fs/stat.c |
| `ksu_handle_sys_reboot` | kernel/reboot.c |
| `ksu_handle_input_handle_event` | drivers/input/input.c |

---

## Troubleshooting

### Build Error: Missing Symbols

```bash
# Verify symbols
./kernel-builder/scripts/check-symbols.sh drivers/kernelsu/ksud.ko vmlinux

# Nếu lỗi, rebuild module
cd drivers/kernelsu
make clean && make
```

### Hook Verification Failed

```bash
# Re-run verification
./kernel-builder/scripts/ksu-hook-verify.sh

# Nếu có incompatible hooks, chạy cleanup
./kernel-builder/scripts/ksu-cleanup-helper.sh
```

### Patch Rejects

```bash
# Tìm các file bị reject
find . -name "*.rej"

# Áp dụng thủ công từng file
# Hoặc dùng patch --force
patch -p1 --force < susfs_patch.patch
```

---

## References

- [ReSukiSU GitHub](https://github.com/ReSukiSU/ReSukiSU)
- [KernelSU Documentation](https://kernelsu.org/)
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3)
- [LLVM/Clang Releases](https://github.com/llvm/llvm-project/releases)
