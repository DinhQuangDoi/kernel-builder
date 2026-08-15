# Kernel Builder — ReSukiSU Integration + CI/CD Toolkit

Bộ công cụ tự động hoá việc tích hợp **ReSukiSU (KernelSU + SUSFS)** vào kernel
non-GKI và thiết lập **GitHub Actions CI/CD** build kernel.

---

## Mục lục

- [TL;DR — Bắt đầu nhanh](#tldr--bắt-đầu-nhanh)
- [Yêu cầu (Prerequisites)](#yêu-cầu-prerequisites)
- [Flow tổng quan (4 Phase)](#flow-tổng-quan-4-phase)
- [1. Cài đặt & GitHub CLI](#1-cài-đặt--github-cli)
- [2. Detect old KSU (Optional)](#2-detect-old-ksu-optional)
- [3. Integrate ReSukiSU](#3-integrate-resukisu)
- [4. Verify Integration](#4-verify-integration)
- [5. Generate CI Workflow](#5-generate-ci-workflow)
- [Quản lý & theo dõi workflow bằng gh](#quản-lý--theo-dõi-workflow-bằng-gh)
- [Build Summary (sau khi workflow xong)](#build-summary-sau-khi-workflow-xong)
- [Scripts Reference](#scripts-reference)
- [Cấu trúc thư mục](#cấu-trúc-thư-mục)
- [Device Config](#device-config)
- [Troubleshooting](#troubleshooting)
- [AI / Agent Guide](#ai--agent-guide)
- [References](#references)
- [License](#license)

---

## TL;DR — Bắt đầu nhanh

```bash
# 1. Copy toolkit vào kernel source
cd /path/to/kernel-source
git clone <repo-cua-ban>/kernel-builder.git kernel-builder

# 2. Detect old KSU (nếu kernel cũ từng có KSU)
./kernel-builder/scripts/detect-old-ksu.sh

# 3. Integrate ReSukiSU
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

# 4. Verify
./kernel-builder/scripts/ksu-compat-check.sh

# 5. Generate workflow (interactive — có hỏi gh login, commit, theo dõi build)
python3 ./kernel-builder/scripts/generate-workflow.py --interactive
```

Kết quả: workflow `.github/workflows/kernel-build.yml` + khi build xong có
flashable zip (AnyKernel3) và Build Summary hiển thị các `CONFIG_KSU*` đã bật +
link tải **ReSukiSU Manager**.

---

## Yêu cầu (Prerequisites)

| Công cụ | Yêu cầu | Cài đặt |
|---------|---------|---------|
| Git | Có | `sudo apt install git` |
| Python 3.8+ | Có | `sudo apt install python3` |
| Kernel source | Android kernel (đã `make defconfig` OK) | — |
| **GitHub CLI (`gh`)** | **Khuyến nghị** | `sudo apt install gh && gh auth login` |

> **Vì sao cần `gh`?** `gh` giúp: commit/push workflow nhanh, kick workflow
> (`gh workflow run`), theo dõi build realtime (`gh run watch`), xem log lỗi
> (`gh run view --log-failed`), tạo release kèm kernel zip (`gh release create`).
>
> Interactive generator sẽ **tự kiểm tra `gh`** và hỏi bạn có muốn đăng nhập +
> commit + theo dõi workflow ngay sau khi sinh workflow.

---

## Flow tổng quan (4 Phase)

```
┌─────────────────────────────────────────────────────────┐
│  PHASE 1: Clean Old KSU                               │
│  ├── detect-old-ksu.sh                               │
│  └── ksu-cleanup-helper.sh  (chỉ khi có old KSU)     │
│                         ↓                              │
│  PHASE 2: KSU Integration                            │
│  ├── Add ReSukiSU (setup.sh)                         │
│  ├── Apply Susfs patches                             │
│  └── Apply inline hooks                              │
│                         ↓                              │
│  PHASE 3: Verification                               │
│  ├── ksu-compat-check.sh                             │
│  ├── ksu-hook-verify.sh                              │
│  └── check-symbols.sh                                │
│                         ↓                              │
│  PHASE 4: CI Generation                              │
│  └── generate-workflow.py (--interactive)            │
│       └── [gh] commit/push + theo dõi build          │
└─────────────────────────────────────────────────────────┘
```

---

## 1. Cài đặt & GitHub CLI

```bash
# Trong thư mục kernel source
git clone <repo-cua-ban>/kernel-builder.git kernel-builder
```

### Kiểm tra GitHub CLI

```bash
gh --version                    # đã cài chưa?
gh auth status                  # đã đăng nhập chưa?
gh auth login                   # đăng nhập (chọn HTTPS + SSH key/browser)
```

Interactive generator sẽ tự hỏi việc này — nhưng bạn nên đăng nhập trước:

```
$ python3 kernel-builder/scripts/generate-workflow.py -i
...
[OK] Workflow generated: .github/workflows/kernel-build.yml
[OK] GitHub CLI da dang nhap: DinhQuangDoi
Commit + push workflow len GitHub ngay? [y/N]:
```

Nếu chưa cài/đăng nhập `gh`, generator sẽ báo và gợi ý lệnh.

---

## 2. Detect old KSU (Optional)

Dành cho kernel cũ từng tích hợp KernelSU (hooks kiểu cũ `ksu_*_hook`).

```bash
cd /path/to/kernel-source
./kernel-builder/scripts/detect-old-ksu.sh
# Nếu báo "Old KSU detected" → cleanup:
./kernel-builder/scripts/ksu-cleanup-helper.sh
```

---

## 3. Integrate ReSukiSU

> **Quan trọng — KernelSU phải là git submodule.** `drivers/kernelsu/Kbuild` chạy
> `git rev-list --count HEAD` để lấy KSU version và sẽ **báo lỗi build** nếu phát
> hiện code bị copy/inline (thiếu `.git`). Id nhất dùng helper sau (thêm submodule
> thật + tạo symlink `drivers/kernelsu`):

```bash
./kernel-builder/scripts/ksu-submodule-setup.sh          # add submodule + symlink
# ./kernel-builder/scripts/ksu-submodule-setup.sh --cleanup  # gỡ

git add .gitmodules KernelSU drivers/kernelsu
git commit -m "Integrate ReSukiSU as submodule"
git push
```

> Workflow sinh ra tự **`submodules: recursive`** khi checkout, và bước *Verify KSU
> Integration* sẽ cảnh báo nếu thiếu submodule (để fail nhanh thay vì lỗi build).

```bash
# (Cách khác) Add ReSukiSU theo setup.sh upstream
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

# Apply Susfs patches (ví dụ kernel 4.19)
curl -sL "https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/refs/heads/mainline/Patches/Patch/susfs_patch_to_4.19.patch" -o susfs_patch.patch
patch -p1 --force < susfs_patch.patch

# Apply inline hooks
curl -sL "https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/refs/heads/mainline/Patches/susfs_inline_hook_patches.sh" -o susfs_inline.sh
bash susfs_inline.sh

# Bật config (non-GKI 4.19 phải dùng inline hook)
#   CONFIG_KSU=y
#   CONFIG_KSU_SUSFS=y
```

> **Lưu ý:** với kernel non-GKI 4.19, bắt buộc `CONFIG_KSU_SUSFS=y`
> (Kconfig default là `KSU_TRACEPOINT_HOOK`, không đúng cho 4.19).

---

## 4. Verify Integration

```bash
./kernel-builder/scripts/ksu-compat-check.sh     # compatibility (16/23 …)
./kernel-builder/scripts/ksu-hook-verify.sh      # hooks đã đúng chưa
./kernel-builder/scripts/check-symbols.sh drivers/kernelsu/ksud.ko vmlinux
```

---

## 5. Generate CI Workflow

```bash
# Interactive (khuyến nghị) — hỏi build local hay GitHub, AK3 nào, gh login
python3 ./kernel-builder/scripts/generate-workflow.py --interactive

# Auto-detect từ kernel source
python3 ./kernel-builder/scripts/generate-workflow.py --detect

# Từ config file
python3 ./kernel-builder/scripts/generate-workflow.py --config device-config.yml
```

### Interactive mode sẽ hỏi gì?

1. Kiểm tra đã integrate ReSukiSU chưa (`drivers/kernelsu`) — chưa thì cảnh báo
2. Hiển thị các **CONFIG_KSU\*** đang bật trong defconfig
3. **Build local** hay **GitHub Actions workflow**?
   - Local → in sẵn lệnh build (out-of-tree `O=out`)
4. (GitHub) **AnyKernel3 nào?**
   - Có sẵn AK3 trong kernel tree → hỏi dùng nó hay AK3 khác
   - Không có sẵn → hỏi dùng mặc định osm0sis hay nhập git URL
5. **GitHub CLI?**
   - Kiểm tra `gh` đã đăng nhập chưa → hỏi đăng nhập nếu chưa
   - Hỏi có commit + push workflow ngay không
   - Hỏi có kick workflow + theo dõi (`gh run watch`) không

---

## Quản lý & theo dõi workflow bằng gh

```bash
# Commit + push workflow (thủ công)
git add .github/workflows/kernel-build.yml
git commit -m "ci: add kernel build workflow"
git push

# Kick workflow thủ công (không cần tag)
gh workflow run kernel-build.yml

# Trigger bằng tag
git tag v1.0 && git push origin v1.0

# Theo dõi build realtime (thoát khi xong / fail)
gh run watch --exit-status

# Xem kết quả gần nhất
gh run list --limit 5
gh run view --log-failed

# Tải artifact (kernel zip) khi build xong
gh run download <run-id> -n kernel-artifacts

# Tạo GitHub Release kèm kernel zip
gh release create v1.0 AnyKernel3/kernel.zip --title "v1.0" --notes "…"
```

---

## Build Summary (sau khi workflow xong)

Khi workflow build xong, step **Build Summary** ghi vào `$GITHUB_STEP_SUMMARY`:

- Device / Kernel / Arch / Toolchain
- **Enabled Config Features**: mọi `CONFIG_KSU* = y` đọc từ `out/.config`
  (sau `make defconfig` → hiển thị đủ sub-option đã resolve, ví dụ
  `CONFIG_KSU_SUSFS`, `CONFIG_KSU_SUSFS_SUS_MOUNT`, `CONFIG_KSU_SUSFS_SUS_KSTAT`…)
- **ReSukiSU Manager**: link tải manager (nightly.link) + guide install

> Link manager có thể đổi qua config `links.manager_url`.

---

## Scripts Reference

### Detection

| Script | Mô tả |
|--------|-------|
| `detect-old-ksu.sh` | Scan old KSU hooks kiểu cũ (2-3 năm trước) |
| `detect-kernel.sh` | Detect kernel version từ Makefile |
| `detect-toolchain.sh` | Detect Clang/GCC toolchain |
| `detect-ksu.sh` | Check current KSU/Susfs status |

### Cleanup

| Script | Mô tả |
|--------|-------|
| `ksu-cleanup-helper.sh` | Safely remove old KSU hooks |

### Verification

| Script | Mô tả |
|--------|-------|
| `ksu-compat-check.sh` | Check kernel compatibility (SELinux, headers, …) |
| `ksu-hook-verify.sh` | Verify hooks installed đúng |
| `check-symbols.sh` | Verify symbols giữa `.ko` và `vmlinux` |

### Generator

| Script | Mô tả |
|--------|-------|
| `generate-workflow.py` | Sinh GitHub Actions workflow (`--interactive` / `--detect` / `--config`) |

---

## Cấu trúc thư mục

```
kernel-builder/
├── scripts/               # Shell/Python scripts
│   ├── detect-*.sh        # Detection scripts
│   ├── ksu-*.sh           # KSU integration/cleanup
│   ├── check-*.sh         # Verification scripts
│   └── generate-workflow.py
├── tools/                 # ReSukiSU kernel tools (make include / C)
│   ├── kernel_compat.mk
│   ├── inline_hook_check.mk
│   ├── manual_hook_check.mk
│   ├── check_symbol.c
│   └── ...
├── skill/                 # Skill markdown (cho AI agent)
│   └── kernel-build-skill.md
├── device-config.yml.example   # Mẫu config cho generator
└── .github/workflows/ci.yml    # Self-check CI cho chính repo này
```

---

## Device Config

```yaml
device:
  codename: "sweetin"
  arch: "arm64"
  defconfig: "vendor/sweetin_defconfig"

toolchain:
  type: "clang"            # "clang" (default) or "gcc"
  clang_version: "17.0.6"  # Official LLVM release (proton-clang đã ngừng)
  gcc_prebuilt: "none"     # "none" = system gcc-aarch64-linux-gnu, "arm" = ARM GNU prebuilt

kernel:
  version: "4.19"
  anykernel: true          # Package flashable AnyKernel3 zip
  #anykernel_url: "https://github.com/custom/AnyKernel3.git"  # Custom AK3 repo
  #anykernel_in_tree: false  # Dùng AK3 dir có sẵn trong kernel tree

ksu:
  integrated: true

upload:
  vmlinux: false           # Upload out/vmlinux? Mặc định FALSE (~200MB khi DEBUG_INFO)

links:
  manager_url: "https://nightly.link/ReSukiSU/ReSukiSU/workflows/build-manager/main"
```

> **Lưu ý upload size:** mặc định KHÔNG upload `out/vmlinux` (kernel có
> `CONFIG_DEBUG_INFO=y` thì vmlinux ~200MB). Bật lại bằng `upload.vmlinux: true`.

Toàn bộ config xem tại [`device-config.yml.example`](device-config.yml.example).
Không cung cấp config thì generator tự detect từ kernel source.

---

## Troubleshooting

### Patch Rejects

```bash
find . -name "*.rej"              # tìm reject
patch -p1 --force < susfs_patch.patch   # force apply
find . -name "*.orig" -delete     # xóa backup
```

### Symbol Mismatch

```bash
cd drivers/kernelsu && make clean && make
./kernel-builder/scripts/check-symbols.sh drivers/kernelsu/ksud.ko vmlinux
```

### Hook Errors

```bash
./kernel-builder/scripts/ksu-cleanup-helper.sh
./kernel-builder/scripts/ksu-hook-verify.sh
```

### Workflow fail ở Package step

Workflow tự fallback: nếu không có AnyKernel3 → vẫn upload `Image`/`Module.symvers`
(`if-no-files-found: ignore`). Kiểm tra `gh run view --log-failed`.

---

## AI / Agent Guide

> Phần này dành cho AI agent hoặc người muốn tự động hoá.

- **Điểm vào chính:** `scripts/generate-workflow.py` (sinh CI workflow).
  Chạy với `--interactive` cho flow đầy đủ (ghi đè `.github/workflows/kernel-build.yml`).
- **Hooks cũ (phải bỏ):** `ksu_vfs_read_hook`, `ksu_input_hook`,
  `ksu_execveat_hook`, `ksu_init_rc_hook` — do `detect-old-ksu.sh` tìm.
- **Hooks mới (bắt buộc có):** `ksu_handle_setresuid`, `ksu_handle_execveat`,
  `ksu_handle_faccessat`, `ksu_handle_sys_read`, `ksu_handle_stat`,
  `ksu_handle_sys_reboot`, `ksu_handle_input_handle_event`.
- **Config cần đảm bảo:** `CONFIG_KSU=y` + `CONFIG_KSU_SUSFS=y` (non-GKI 4.19).
- **CI toolchain:** LLVM/Clang chính thức (`clang_version`) + `gcc-aarch64-linux-gnu`
  (hybrid). Không dùng Proton Clang (đã ngừng). Build out-of-tree bằng `O=out`
  (tránh `KBUILD_OUTPUT` hardcode trong kernel Makefile).
- **Self-check CI:** `.github/workflows/ci.yml` (bash -n, py_compile, generator smoke).
- **Chi tiết từng bước:** đọc `skill/kernel-build-skill.md`.

---

## References

- [ReSukiSU](https://github.com/ReSukiSU/ReSukiSU)
- [ReSukiSU Guide](https://resukisu.github.io/guide/install.html)
- [KernelSU](https://kernelsu.org/)
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3)
- [LLVM/Clang Releases](https://github.com/llvm/llvm-project/releases)
- [NonGKI Kernel Build](https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd)

## License

MIT License — xem [`LICENSE`](LICENSE)
