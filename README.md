# Kernel Builder - ReSukiSU Integration + CI/CD Automation

Toolkit giúp tự động hoá việc tích hợp ReSukiSU (KernelSU) vào kernel non-GKI và thiết lập GitHub Actions CI/CD.

## Features

- **Auto-detect**: Tự động phát hiện kernel version, toolchain, KSU status
- **Old KSU Cleanup**: Tìm và loại bỏ KSU hooks cũ (2-3 năm) mà không ảnh hưởng code khác
- **Hook Verification**: Dùng ReSukiSU kernel tools để verify hooks
- **CI/CD Generator**: Tạo GitHub Actions workflow từ config hoặc auto-detect

## Quick Start

### 1. Clone/Copy vào kernel source

```bash
# Trong thư mục kernel source
git clone https://github.com/your/kernel-builder.git kernel-builder
cd kernel-builder
```

### 2. Detect Old KSU (Optional - nếu kernel có KSU cũ)

```bash
cd /path/to/kernel-source
./kernel-builder/scripts/detect-old-ksu.sh

# Nếu có old KSU, chạy cleanup
./kernel-builder/scripts/ksu-cleanup-helper.sh
```

### 3. Integrate ReSukiSU

```bash
# Add ReSukiSU
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

# Apply Susfs patches
curl -sL "https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/refs/heads/mainline/Patches/Patch/susfs_patch_to_4.19.patch" -o susfs_patch.patch
patch -p1 --force < susfs_patch.patch

# Apply inline hooks
curl -sL "https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/refs/heads/mainline/Patches/susfs_inline_hook_patches.sh" -o susfs_inline.sh
bash susfs_inline.sh
```

### 4. Verify Integration

```bash
./kernel-builder/scripts/ksu-compat-check.sh
./kernel-builder/scripts/ksu-hook-verify.sh
```

### 5. Generate CI Workflow

```bash
# Auto-detect
python3 ./kernel-builder/scripts/generate-workflow.py --detect

# Hoặc từ config
python3 ./kernel-builder/scripts/generate-workflow.py --config device-config.yml
```

## Scripts

### Detection Scripts

| Script | Mô tả |
|--------|-------|
| `detect-old-ksu.sh` | Scan old KSU hooks từ 2-3 năm trước |
| `detect-kernel.sh` | Detect kernel version |
| `detect-toolchain.sh` | Detect Clang/GCC toolchain |
| `detect-ksu.sh` | Check current KSU/Susfs status |

### Cleanup Scripts

| Script | Mô tả |
|--------|-------|
| `ksu-cleanup-helper.sh` | Safely remove old KSU hooks |

### Verification Scripts

| Script | Mô tả |
|--------|-------|
| `ksu-compat-check.sh` | Check kernel compatibility |
| `ksu-hook-verify.sh` | Verify hooks installed |
| `check-symbols.sh` | Verify symbols match |

### Generator Scripts

| Script | Mô tả |
|--------|-------|
| `generate-workflow.py` | Generate GitHub Actions workflow |

## Cấu trúc thư mục

```
kernel-builder/
├── scripts/              # Shell/Python scripts
│   ├── detect-*.sh     # Detection scripts
│   ├── ksu-*.sh        # KSU integration/cleanup
│   ├── check-*.sh      # Verification scripts
│   └── generate-*.py   # Workflow generator
├── tools/               # ReSukiSU kernel tools
│   ├── kernel_compat.mk
│   ├── inline_hook_check.mk
│   ├── manual_hook_check.mk
│   ├── check_symbol.c
│   └── ...
└── skill/               # Cursor Skill markdown
    └── kernel-build-skill.md
```

## Workflow hoàn chỉnh

```
┌─────────────────────────────────────────────────────────┐
│  PHASE 1: Clean Old KSU                               │
│  ├── detect-old-ksu.sh                               │
│  └── ksu-cleanup-helper.sh                           │
│                         ↓                              │
│  PHASE 2: KSU Integration                            │
│  ├── Add ReSukiSU                                    │
│  ├── Apply Susfs patches                            │
│  └── Apply inline hooks                             │
│                         ↓                              │
│  PHASE 3: Verification                               │
│  ├── ksu-compat-check.sh                            │
│  ├── ksu-hook-verify.sh                            │
│  └── check-symbols.sh                              │
│                         ↓                              │
│  PHASE 4: CI Generation                              │
│  └── generate-workflow.py                           │
└─────────────────────────────────────────────────────────┘
```

## Hook Verification

### Incompatible Hooks (Old - Must Remove)

- `ksu_vfs_read_hook`
- `ksu_input_hook`
- `ksu_execveat_hook`
- `ksu_init_rc_hook`

### Required Hooks (New - Must Have)

- `ksu_handle_setresuid`
- `ksu_handle_execveat`
- `ksu_handle_faccessat`
- `ksu_handle_sys_read`
- `ksu_handle_stat`
- `ksu_handle_sys_reboot`
- `ksu_handle_input_handle_event`

## Device Config Example

```yaml
device:
  codename: "sweetin"
  defconfig: "arch/arm64/configs/vendor/sweetin_defconfig"

toolchain:
  type: "clang"
  clang_prebuilt: "proton-clang@20240901"

kernel:
  version: "4.19"
  anykernel: true

ksu:
  integrated: true
```

## Troubleshooting

### Patch Rejects

```bash
# Tìm rejects
find . -name "*.rej"

# Apply thủ công hoặc force
patch -p1 --force < susfs_patch.patch

# Xóa backups
find . -name "*.orig" -delete
```

### Symbol Mismatch

```bash
# Rebuild ksud.ko
cd drivers/kernelsu
make clean && make

# Verify lại
./kernel-builder/scripts/check-symbols.sh drivers/kernelsu/ksud.ko vmlinux
```

### Hook Errors

```bash
# Cleanup old KSU trước
./kernel-builder/scripts/ksu-cleanup-helper.sh

# Verify lại
./kernel-builder/scripts/ksu-hook-verify.sh
```

## References

- [ReSukiSU](https://github.com/ReSukiSU/ReSukiSU)
- [KernelSU](https://kernelsu.org/)
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3)
- [Proton Clang](https://github.com/kdrag0n/proton-clang)
- [NonGKI Kernel Build](https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd)

## License

MIT License
