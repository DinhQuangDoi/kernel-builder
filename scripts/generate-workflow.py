#!/usr/bin/env python3
"""
generate-workflow.py - Generate GitHub Actions workflow from device config

Usage:
    python generate-workflow.py [--config <config-file>] [--output <output-file>]
    python generate-workflow.py --detect  # Auto-detect from kernel source
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Dict, Any, List, Optional

# Colors for terminal output
class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    NC = '\033[0m'  # No Color
    BOLD = '\033[1m'

def print_info(msg: str):
    print(f"{Colors.BLUE}[INFO]{Colors.NC} {msg}")

def print_success(msg: str):
    print(f"{Colors.GREEN}[OK]{Colors.NC} {msg}")

def print_warning(msg: str):
    print(f"{Colors.YELLOW}[WARN]{Colors.NC} {msg}")

def print_error(msg: str):
    print(f"{Colors.RED}[ERROR]{Colors.NC} {msg}")

def detect_kernel_version() -> Dict[str, Any]:
    """Detect kernel version from Makefile"""
    result = {
        'version': '4',
        'patchlevel': '19',
        'sublevel': '0',
        'extraversion': '',
        'name': ''
    }
    
    if not os.path.exists('Makefile'):
        print_warning("Makefile not found, using defaults")
        return result
    
    with open('Makefile', 'r') as f:
        content = f.read()
    
    for line in content.split('\n'):
        line = line.strip()
        if line.startswith('VERSION'):
            result['version'] = line.split('=')[-1].strip()
        elif line.startswith('PATCHLEVEL'):
            result['patchlevel'] = line.split('=')[-1].strip()
        elif line.startswith('SUBLEVEL'):
            result['sublevel'] = line.split('=')[-1].strip()
        elif line.startswith('EXTRAVERSION'):
            result['extraversion'] = line.split('=')[-1].strip()
        elif line.startswith('NAME'):
            result['name'] = line.split('=')[-1].strip()
    
    return result

def detect_toolchain() -> Dict[str, Any]:
    """Detect toolchain from Makefile"""
    result = {
        'type': 'clang',
        'path': '',
        'cross_compile': ''
    }
    
    if not os.path.exists('Makefile'):
        return result
    
    with open('Makefile', 'r') as f:
        content = f.read()
    
    # Check for clang
    if 'clang' in content:
        result['type'] = 'clang'
        # Try to extract clang path
        match = re.search(r'CC\s*[=:]\s*(\S+)', content)
        if match:
            result['path'] = match.group(1)
    # Check for GCC
    elif 'CROSS_COMPILE' in content:
        result['type'] = 'gcc'
        match = re.search(r'CROSS_COMPILE\s*[=:]\s*(\S+)', content)
        if match:
            result['cross_compile'] = match.group(1)
    
    return result

def detect_defconfig() -> Optional[str]:
    """Find defconfig file"""
    patterns = [
        'arch/arm64/configs/*_defconfig',
        'arch/arm/configs/*_defconfig',
        'arch/x86/configs/*_defconfig',
    ]
    
    for pattern in patterns:
        matches = list(Path('.').glob(pattern))
        if matches:
            return str(matches[0])
    
    return None

def detect_arch() -> str:
    """Detect architecture"""
    if os.path.exists('arch/arm64/configs'):
        return 'arm64'
    elif os.path.exists('arch/arm/configs'):
        return 'arm'
    elif os.path.exists('arch/x86/configs'):
        return 'x86'
    return 'arm64'  # default


def find_defconfig_path(arch: str, defconfig: str) -> Optional[str]:
    """Resolve the defconfig file path, or None if not found."""
    if not defconfig or defconfig == 'defconfig':
        return None
    if os.path.exists(defconfig):
        return defconfig
    for base in (f'arch/{arch}/configs', 'arch/arm64/configs', 'arch/arm/configs', 'arch/x86/configs'):
        candidate = os.path.join(base, defconfig)
        if os.path.exists(candidate):
            return candidate
    return None


def detect_enabled_features(arch: str, defconfig: str) -> List[str]:
    """Detect enabled KSU/SUSFS config features from .config or defconfig."""
    lines = []
    if os.path.exists('.config'):
        with open('.config') as f:
            lines = [line.strip() for line in f if line.strip().startswith('CONFIG_')]
    else:
        cfg_path = find_defconfig_path(arch, defconfig)
        if cfg_path:
            with open(cfg_path) as f:
                lines = [line.strip() for line in f if line.strip().startswith('CONFIG_')]
    if not lines:
        return []

    features = []
    for line in lines:
        if line.endswith('=y') or line.endswith('=m'):
            name = line.split('=')[0]
            if name.startswith('CONFIG_KSU'):
                features.append(name)
    return sorted(set(features))

def load_config(config_path: str) -> Dict[str, Any]:
    """Load device config from YAML-like file"""
    config = {
        'device': {},
        'toolchain': {},
        'kernel': {},
        'ksu': {},
        'github': {},
        'upload': {},
        'links': {}
    }
    
    if not os.path.exists(config_path):
        print_warning(f"Config file not found: {config_path}")
        return config
    
    # Simple YAML-like parser
    current_section = None
    with open(config_path, 'r') as f:
        for line in f:
            line = line.rstrip()
            
            # Skip comments and empty lines
            if not line or line.strip().startswith('#'):
                continue
            
            # Section header
            if line and not line.startswith(' ') and not line.startswith('\t'):
                section = line.rstrip(':').strip().lower()
                if section in config:
                    current_section = section
            
            # Key-value pair
            elif ':' in line and current_section:
                key, value = line.split(':', 1)
                key = key.strip().lower()
                value = value.strip()
                
                # Strip surrounding quotes
                if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                    value = value[1:-1]
                
                # Handle booleans
                if value.lower() == 'true':
                    value = True
                elif value.lower() == 'false':
                    value = False
                
                config[current_section][key] = value
    
    return config

def generate_workflow(config: Dict[str, Any]) -> str:
    """Generate GitHub Actions workflow YAML"""

    device = config.get('device', {})
    toolchain = config.get('toolchain', {})
    kernel = config.get('kernel', {})
    ksu = config.get('ksu', {})
    github_config = config.get('github', {})

    # Get values with defaults
    device_name = device.get('codename', 'kernel')
    defconfig = str(device.get('defconfig', 'defconfig'))
    arch = device.get('arch', detect_arch())

    # Normalize detect-style full path (arch/arm64/configs/foo_defconfig) to make target form
    m = re.match(r'^arch/[^/]+/configs/(.+)$', defconfig)
    if m:
        defconfig = m.group(1)

    tc_type = str(toolchain.get('type', 'clang')).lower()
    clang_version = toolchain.get('clang_version', '17.0.6')
    gcc_version = str(toolchain.get('gcc_version', '13.2.rel1'))
    use_gcc_prebuilt = str(toolchain.get('gcc_prebuilt', 'none')).lower() in ('arm', 'yes', 'true', '1')

    # Backwards compatibility: proton-clang is dead (release assets removed),
    # so default to official LLVM releases.
    clang_prebuilt = str(toolchain.get('clang_prebuilt', ''))
    if clang_prebuilt.startswith('proton-clang'):
        print_warning("proton-clang is no longer available, using official LLVM clang instead")

    det = detect_kernel_version()
    ver = str(kernel.get('version') or det.get('version', ''))
    pl = str(kernel.get('patchlevel') or det.get('patchlevel', ''))
    kernel_version = kernel.get('full_version') or f"{ver}.{pl}"
    use_anykernel = kernel.get('anykernel', True)

    ksu_integrated = ksu.get('integrated', False)

    anykernel_in_tree = kernel.get('anykernel_in_tree', False)
    anykernel_url = str(kernel.get('anykernel_url') or 'https://github.com/osm0sis/AnyKernel3.git')
    upload = config.get('upload', {})
    upload_vmlinux = upload.get('vmlinux', False)
    links = config.get('links', {})
    manager_url = str(links.get('manager_url') or 'https://nightly.link/ReSukiSU/ReSukiSU/workflows/build-manager/main')

    if tc_type == 'gcc':
        cross_compile = 'aarch64-none-linux-gnu-' if use_gcc_prebuilt else 'aarch64-linux-gnu-'
    else:
        cross_compile = 'aarch64-linux-gnu-'
        clang_triple = 'aarch64-linux-gnu-'

    # ---- Setup toolchain steps -------------------------------------------------
    if tc_type == 'gcc':
        if use_gcc_prebuilt:
            toolchain_step = f"""        # Download ARM GNU toolchain {gcc_version}
        curl -sL "https://developer.arm.com/-/media/Files/downloads/gnu/{gcc_version}/binrel/arm-gnu-toolchain-{gcc_version}-x86_64-aarch64-none-linux-gnu.tar.xz" -o gcc.tar.xz
        tar -xJf gcc.tar.xz
        rm gcc.tar.xz
        mv arm-gnu-toolchain-* gcc
        echo "PATH=$(pwd)/gcc/bin:$PATH" >> $GITHUB_ENV
        echo "CROSS_COMPILE=aarch64-none-linux-gnu-" >> $GITHUB_ENV
"""
        else:
            toolchain_step = """        # System aarch64 GCC (installed via apt in the deps step)
        echo "CROSS_COMPILE=aarch64-linux-gnu-" >> $GITHUB_ENV
"""
    else:
        toolchain_step = f"""        # Download official LLVM/Clang {clang_version}
        curl -sL "https://github.com/llvm/llvm-project/releases/download/llvmorg-{clang_version}/clang+llvm-{clang_version}-x86_64-linux-gnu-ubuntu-22.04.tar.xz" -o llvm.tar.xz
        tar -xJf llvm.tar.xz
        rm llvm.tar.xz
        mv clang+llvm-* clang
        echo "PATH=$(pwd)/clang/bin:$PATH" >> $GITHUB_ENV
"""

    # ---- Build steps -----------------------------------------------------------
    ccache_step = f"""    - name: Setup ccache
      uses: hendrikmuhs/ccache-action@v1.2.22
      with:
        key: build-kernel-${{{{ env.DEVICE_CODENAME }}}}-${{{{ env.TOOLCHAIN_TYPE }}}}
        max-size: 2G

"""
    if tc_type == 'gcc':
        build_step = f"""        make O=out ARCH={arch} CROSS_COMPILE={cross_compile} {defconfig}

        make O=out -j$(nproc --all) ARCH={arch} CROSS_COMPILE={cross_compile}
"""
    else:
        build_step = f"""        make O=out ARCH={arch} \\
          CC="ccache clang" CLANG_TRIPLE={clang_triple} CROSS_COMPILE={cross_compile} {defconfig}

        make O=out -j$(nproc --all) ARCH={arch} \\
          CC="ccache clang" CLANG_TRIPLE={clang_triple} CROSS_COMPILE={cross_compile}
"""

    ccache_stats_step = f"""    - name: ccache stats
      run: |
        ccache -s
        echo "### Ccache stats" >> $GITHUB_STEP_SUMMARY
        ccache -s | grep -E "Hits|Misses|Cache size|Hit rate" | sed 's/^/- \|/' >> $GITHUB_STEP_SUMMARY

"""

    # ---- AnyKernel3 steps ------------------------------------------------------
    if use_anykernel and not anykernel_in_tree:
        anykernel_clone = f"""        git clone --depth=1 {anykernel_url} AnyKernel3 \\
          || echo "::warning::AnyKernel3 clone failed, will upload built Image only"
"""
        anykernel_download_step = f"""    - name: Download AnyKernel3
      run: |
{anykernel_clone}
"""
    else:
        anykernel_download_step = ""
    if use_anykernel:
        if anykernel_in_tree:
            package_step = f"""        # Use AnyKernel3 already present in the kernel tree
        AK3_DIR=""
        for d in AnyKernel3 anykernel3 AnyKernel AK3; do
          if [ -d "$d" ]; then AK3_DIR="$d"; break; fi
        done
        if [ -z "$AK3_DIR" ]; then
          echo "::warning::No in-tree AnyKernel3 found, skipping zip packaging"
          exit 0
        fi

        cd "$AK3_DIR"
        # Copy kernel Image
        if [ -f ../out/arch/{arch}/boot/Image ]; then
          cp ../out/arch/{arch}/boot/Image .
        elif [ -f ../out/arch/{arch}/boot/Image.gz-dtb ]; then
          cp ../out/arch/{arch}/boot/Image.gz-dtb .
        elif [ -f ../out/arch/{arch}/boot/zImage ]; then
          cp ../out/arch/{arch}/boot/zImage .
        fi

        # Copy dtbs if exists
        if [ -d ../out/arch/{arch}/boot/dts ]; then
          mkdir -p dtbs
          cp ../out/arch/{arch}/boot/dts/*/*.dtb dtbs/ 2>/dev/null || true
        fi

        # Create zip
        zip -r kernel.zip *

        echo "KERNEL_ZIP=kernel.zip" >> $GITHUB_ENV
"""
        else:
            package_step = f"""        if [ ! -d AnyKernel3 ]; then
          echo "::warning::AnyKernel3 not available, skipping zip packaging"
          exit 0
        fi

        cd AnyKernel3
        # Copy kernel Image
        if [ -f ../out/arch/{arch}/boot/Image ]; then
          cp ../out/arch/{arch}/boot/Image .
        elif [ -f ../out/arch/{arch}/boot/Image.gz-dtb ]; then
          cp ../out/arch/{arch}/boot/Image.gz-dtb .
        elif [ -f ../out/arch/{arch}/boot/zImage ]; then
          cp ../out/arch/{arch}/boot/zImage .
        fi

        # Copy dtbs if exists
        if [ -d ../out/arch/{arch}/boot/dts ]; then
          mkdir -p dtbs
          cp ../out/arch/{arch}/boot/dts/*/*.dtb dtbs/ 2>/dev/null || true
        fi

        # Create zip
        zip -r kernel.zip *

        echo "KERNEL_ZIP=kernel.zip" >> $GITHUB_ENV
"""
    else:
        package_step = ""

    ksu_check_step = ""
    if ksu_integrated:
        ksu_check_step = """    - name: Verify KSU Integration
      run: |
        echo "Checking for KSU integration..."
        if [ ! -d "drivers/kernelsu" ]; then
          echo "::error::KSU not integrated: drivers/kernelsu missing."
          echo "  Run: kernel-builder/scripts/ksu-submodule-setup.sh"
          exit 1
        fi
        echo "KSU found in drivers/kernelsu/"
        if ! git ls-files --stage --error-unmatch KernelSU >/dev/null 2>&1; then
          echo "::warning::KernelSU is not a git submodule."
        elif [ "$(git submodule status KernelSU 2>&1 | cut -c1)" = "-" ]; then
          echo "::warning::KernelSU submodule not initialized. Commit .gitmodules so checkout uses 'submodules: recursive'."
        else
          echo "KernelSU is a registered git submodule (OK)."
        fi

"""

    vmlinux_path = "          out/vmlinux\n" if upload_vmlinux else ""
    if use_anykernel:
        upload_paths = f"""        path: |
          AnyKernel3/kernel.zip
          anykernel3/kernel.zip
          out/arch/{arch}/boot/Image
          out/arch/{arch}/boot/Image.gz-dtb
          out/arch/{arch}/boot/zImage
{vmlinux_path}          out/Module.symvers
        if-no-files-found: ignore
"""
        vmlinux_path = "          out/vmlinux\n" if upload_vmlinux else ""
    else:
        upload_paths = f"""        path: |
          out/arch/{arch}/boot/Image
          out/arch/{arch}/boot/Image.gz-dtb
          out/arch/{arch}/boot/zImage
{vmlinux_path}          out/Module.symvers
        if-no-files-found: ignore
"""

    # Enabled features are resolved at build time from the generated out/.config
    feature_lines = """        if [ -f out/.config ]; then
          if grep -qE '^CONFIG_KSU.*=y$' out/.config; then
            grep -E '^CONFIG_KSU.*=y$' out/.config | sed 's/=y$//; s/^/- `/; s/$/`: enabled/' >> $GITHUB_STEP_SUMMARY
          else
            echo "- No CONFIG_KSU* features found" >> $GITHUB_STEP_SUMMARY
          fi
        else
          echo "- out/.config not found" >> $GITHUB_STEP_SUMMARY
        fi
"""

    workflow = f"""name: Kernel Build

on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:
    inputs:
      debug:
        description: 'Enable debug mode'
        required: false
        default: 'false'

env:
  DEVICE_CODENAME: {device_name}
  ARCH: {arch}
  DEFCONFIG: {defconfig}
  TOOLCHAIN_TYPE: {tc_type}
  KERNEL_VERSION: {kernel_version}
  KERNEL_OUT: out
  # ccache tweaks for fast rebuilds
  CCACHE_COMPILERCHECK: "%compiler% -dumpmachine; %compiler% -dumpversion"
  CCACHE_NOHASHDIR: "true"
  CCACHE_HARDLINK: "true"

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
    - name: Checkout repository
      uses: actions/checkout@v4
      with:
        fetch-depth: 1
        submodules: recursive

    - name: Install dependencies
      run: |
        sudo apt-get update && sudo apt-get install -y \\
          build-essential \\
          bc \\
          binutils \\
          ccache \\
          gcc-aarch64-linux-gnu \\
          git \\
          curl \\
          xz-utils \\
          zip \\
          python3 \\
          python3-pip
        pip3 install --user pyyaml

    - name: Setup toolchain
      run: |
        mkdir -p toolchain
        cd toolchain
{toolchain_step}

{anykernel_download_step}{ksu_check_step}{ccache_step}    - name: Build kernel
      run: |
{build_step}{ccache_stats_step}
{('    - name: Package AnyKernel3\n      run: |\n' + package_step) if package_step else ''}
    - name: Upload artifacts
      uses: actions/upload-artifact@v4
      with:
        name: kernel-artifacts
{upload_paths}
    - name: Build Summary
      run: |
        echo "## Build Summary" >> $GITHUB_STEP_SUMMARY
        echo "- Device: ${{{{ env.DEVICE_CODENAME }}}}" >> $GITHUB_STEP_SUMMARY
        echo "- Kernel: ${{{{ env.KERNEL_VERSION }}}}" >> $GITHUB_STEP_SUMMARY
        echo "- Architecture: ${{{{ env.ARCH }}}}" >> $GITHUB_STEP_SUMMARY
        echo "- Toolchain: ${{{{ env.TOOLCHAIN_TYPE }}}}" >> $GITHUB_STEP_SUMMARY
        echo "" >> $GITHUB_STEP_SUMMARY
        echo "### Enabled Config Features" >> $GITHUB_STEP_SUMMARY
{feature_lines}
        echo "" >> $GITHUB_STEP_SUMMARY
        echo "### ReSukiSU Manager" >> $GITHUB_STEP_SUMMARY
        echo "- [Download ReSukiSU Manager]({manager_url})" >> $GITHUB_STEP_SUMMARY
        echo "- [ReSukiSU Guide](https://resukisu.github.io/guide/install.html)" >> $GITHUB_STEP_SUMMARY
"""

    return workflow

def ask_yes_no(prompt: str, default: bool = True) -> bool:
    """Ask a yes/no question on the terminal."""
    hint = "[Y/n]" if default else "[y/N]"
    while True:
        ans = input(f"{prompt} {hint}: ").strip().lower()
        if not ans:
            return default
        if ans in ('y', 'yes'):
            return True
        if ans in ('n', 'no'):
            return False
        print("  Vui long tra loi y hoac n.")


def find_in_tree_ak3() -> str:
    """Return the AnyKernel3 directory already present in the kernel tree, or ''."""
    for d in ('AnyKernel3', 'anykernel3', 'AnyKernel', 'AK3'):
        if os.path.isdir(d):
            return d
    return ''


def ask_ak3_url(kernel_cfg: Dict[str, Any]) -> None:
    """Ask the user for a custom AnyKernel3 git URL."""
    url = input("  AnyKernel3 git URL (Enter = mac dinh osm0sis/AnyKernel3): ").strip()
    if url:
        kernel_cfg['anykernel_url'] = url


def run_interactive() -> None:
    """Interactive setup: ask build method and AnyKernel3 preferences."""
    print()
    print_info("Phan tich kernel source...")

    config = {
        'device': {
            'codename': 'kernel',
            'arch': detect_arch(),
            'defconfig': detect_defconfig() or 'defconfig',
        },
        'toolchain': detect_toolchain(),
        'kernel': detect_kernel_version(),
        'ksu': {'integrated': os.path.exists('drivers/kernelsu')},
        'github': {},
        'upload': {},
        'links': {},
    }

    if not os.path.exists('drivers/kernelsu'):
        print_warning("Khong thay drivers/kernelsu - kernel chua integrate ReSukiSU?")
        if not ask_yes_no("Van tiep tuc?", default=False):
            return

    print_info(f"Kernel: {config['kernel'].get('version')}.{config['kernel'].get('patchlevel')}")
    print_info(f"Defconfig: {config['device']['defconfig']} | Arch: {config['device']['arch']}")

    features = detect_enabled_features(config['device']['arch'], config['device']['defconfig'])
    if features:
        print_info("Config features dang bat (CONFIG_KSU*):")
        for f in features:
            print(f"  - {f} = y")
    else:
        print_warning("Khong phat hien CONFIG_KSU* nao trong config.")

    print()
    print_info("Chon phuong thuc build:")
    print("  1) GitHub Actions workflow (CI)")
    print("  2) Build local")
    choice = input("Lua chon [1/2] (mac dinh 1): ").strip()

    if choice == '2':
        print_local_build_commands(config)
        return

    # GitHub workflow path -> AnyKernel3 questions
    kernel_cfg = config['kernel']
    if kernel_cfg.get('anykernel', True):
        in_tree = find_in_tree_ak3()
        if in_tree:
            print_info(f"Phat hien AnyKernel3 co san trong kernel tree: {in_tree}")
            if ask_yes_no(f"Dung AnyKernel3 co san ({in_tree})?", default=True):
                kernel_cfg['anykernel_in_tree'] = True
            else:
                ask_ak3_url(kernel_cfg)
        else:
            print_info("Khong co AnyKernel3 trong kernel tree.")
            if not ask_yes_no("Dung AnyKernel3 mac dinh (osm0sis)?", default=True):
                ask_ak3_url(kernel_cfg)

    workflow = generate_workflow(config)

    output = '.github/workflows/kernel-build.yml'
    os.makedirs(os.path.dirname(output), exist_ok=True)
    with open(output, 'w') as f:
        f.write(workflow)

    print_success(f"Workflow generated: {output}")
    print()
    print_info("Next steps:")
    print("  1. Review .github/workflows/kernel-build.yml")
    print("  2. Commit va push len GitHub")
    print("  3. Tao tag de trigger build: git tag v1.0 && git push origin v1.0")
    print("  4. Sau khi build xong: tai ReSukiSU Manager tai")
    print("     https://nightly.link/ReSukiSU/ReSukiSU/workflows/build-manager/main")

    gh_setup(output)


def check_gh() -> str:
    """Check GitHub CLI availability and login state: 'loggedin' | 'notloggedin' | 'missing'."""
    if not shutil.which('gh'):
        return 'missing'
    try:
        result = subprocess.run(
            ['gh', 'auth', 'status'], capture_output=True, text=True, timeout=15
        )
    except (subprocess.SubprocessError, OSError):
        return 'missing'
    if result.returncode == 0:
        return 'loggedin'
    return 'notloggedin'


def gh_username() -> Optional[str]:
    """Return the logged-in GitHub username, or None."""
    try:
        result = subprocess.run(
            ['gh', 'api', 'user', '--jq', '.login'],
            capture_output=True, text=True, timeout=15,
        )
    except (subprocess.SubprocessError, OSError):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def gh_setup(workflow_path: str) -> None:
    """Ask about GitHub CLI login, then offer commit/push and workflow watch."""
    state = check_gh()
    print()
    if state == 'missing':
        print_warning("Khong thay GitHub CLI (gh).")
        print("  -> Gh khong co se kho quan ly/theo doi workflow va commit hon.")
        if ask_yes_no("Cai dat va dang nhap gh ngay?", default=False):
            print("  Chay: sudo apt-get install gh && gh auth login")
            print("  Sau do chay lai lenh nay.")
        return

    if state == 'notloggedin':
        print_warning("GitHub CLI da cai nhung CHUA dang nhap.")
        if ask_yes_no("Dang nhap GitHub ngay (gh auth login)?", default=True):
            subprocess.run(['gh', 'auth', 'login'])
            if check_gh() != 'loggedin':
                print_warning("Chua dang nhap thanh cong. Chay lai sau: gh auth login")
                return
    else:
        user = gh_username()
        print_success(f"GitHub CLI da dang nhap: {user or 'unknown'}")

    if check_gh() != 'loggedin':
        return

    if not os.path.isdir('.git'):
        print_warning("Day khong phai git repo - bo qua commit/push.")
        print_info("Theo doi manual: gh run watch .github/workflows/kernel-build.yml")
        return

    if ask_yes_no("Commit + push workflow len GitHub ngay?", default=False):
        subprocess.run(['git', 'add', workflow_path])
        subprocess.run(['git', 'commit', '-m', 'ci: add kernel build workflow'])
        subprocess.run(['git', 'push'])
        print_success("Da commit va push.")
        if ask_yes_no("Kick workflow (workflow_dispatch) va theo doi (gh run watch)?", default=True):
            subprocess.run(['gh', 'workflow', 'run', workflow_path])
            subprocess.run(['gh', 'run', 'watch', '--exit-status'])
    else:
        print_info("Ban co the tu commit & theo doi:")
        print(f"  git add {workflow_path} && git commit -m 'ci: add kernel build workflow' && git push")
        print(f"  gh workflow run {workflow_path} && gh run watch --exit-status")


def print_local_build_commands(config: Dict[str, Any]) -> None:
    """Print local build commands for the detected toolchain."""
    arch = config['device']['arch']
    defconfig = config['device']['defconfig']
    tc_type = str(config['toolchain'].get('type', 'clang')).lower()

    print()
    print_info("Build local (out-of-tree, O=out):")
    if tc_type == 'gcc':
        gcc_prebuilt = str(config['toolchain'].get('gcc_prebuilt', 'none')).lower()
        cross = 'aarch64-none-linux-gnu-' if gcc_prebuilt in ('arm', 'yes', 'true', '1') else 'aarch64-linux-gnu-'
        print(f"  make O=out ARCH={arch} CROSS_COMPILE={cross} {defconfig}")
        print(f"  make O=out -j$(nproc) ARCH={arch} CROSS_COMPILE={cross}")
    else:
        print(f"  make O=out ARCH={arch} CC=clang CLANG_TRIPLE=aarch64-linux-gnu- \\")
        print(f"    CROSS_COMPILE=aarch64-linux-gnu- {defconfig}")
        print(f"  make O=out -j$(nproc) ARCH={arch} CC=clang CLANG_TRIPLE=aarch64-linux-gnu- \\")
        print(f"    CROSS_COMPILE=aarch64-linux-gnu-")
    print()
    print("  Ket qua: out/arch/arm64/boot/Image, out/vmlinux (neu can)")

def main():
    parser = argparse.ArgumentParser(
        description='Generate GitHub Actions workflow for kernel building'
    )
    parser.add_argument(
        '-c', '--config',
        default='device-config.yml',
        help='Device config file (default: device-config.yml)'
    )
    parser.add_argument(
        '-o', '--output',
        default='.github/workflows/kernel-build.yml',
        help='Output workflow file (default: .github/workflows/kernel-build.yml)'
    )
    parser.add_argument(
        '--detect',
        action='store_true',
        help='Auto-detect settings from kernel source'
    )
    parser.add_argument(
        '-i', '--interactive',
        action='store_true',
        help='Interactive setup: ask build method and AnyKernel3 preferences'
    )
    parser.add_argument(
        '-v', '--verbose',
        action='store_true',
        help='Verbose output'
    )
    
    args = parser.parse_args()
    
    print(f"{Colors.BOLD}{Colors.BLUE}========================================{Colors.NC}")
    print(f"{Colors.BOLD}{Colors.BLUE}  Kernel Workflow Generator v2.1{Colors.NC}")
    print(f"{Colors.BOLD}{Colors.BLUE}========================================{Colors.NC}")
    print()
    
    # Interactive mode
    if args.interactive:
        run_interactive()
        return
    
    # Load config
    if args.detect:
        print_info("Auto-detecting settings from kernel source...")
        config = {
            'device': {
                'defconfig': detect_defconfig() or 'defconfig',
                'arch': detect_arch()
            },
            'toolchain': detect_toolchain(),
            'kernel': detect_kernel_version(),
            'ksu': {'integrated': os.path.exists('drivers/kernelsu')},
            'github': {}
        }
        
        if args.verbose:
            print_info(f"Detected kernel: {config['kernel']}")
            print_info(f"Detected toolchain: {config['toolchain']}")
            print_info(f"Detected defconfig: {config['device']['defconfig']}")
    else:
        config = load_config(args.config)
        if not config.get('device'):
            print_warning("Empty config, using auto-detection")
            config = {
                'device': {'defconfig': detect_defconfig() or 'defconfig'},
                'toolchain': detect_toolchain(),
                'kernel': detect_kernel_version(),
                'ksu': {'integrated': os.path.exists('drivers/kernelsu')},
                'github': {}
            }
    
    # Generate workflow
    workflow = generate_workflow(config)
    
    # Create output directory
    output_dir = os.path.dirname(args.output)
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)
    
    # Write workflow
    with open(args.output, 'w') as f:
        f.write(workflow)
    
    print_success(f"Workflow generated: {args.output}")
    print()
    print_info("Next steps:")
    print("  1. Review the generated workflow")
    print("  2. Customize if needed")
    print("  3. Push to GitHub")
    print("  4. Create a tag to trigger build: git tag v1.0 && git push origin v1.0")

if __name__ == '__main__':
    main()
