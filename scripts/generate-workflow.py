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
import sys
import re
from pathlib import Path
from typing import Dict, Any, Optional

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

def load_config(config_path: str) -> Dict[str, Any]:
    """Load device config from YAML-like file"""
    config = {
        'device': {},
        'toolchain': {},
        'kernel': {},
        'ksu': {},
        'github': {}
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
    defconfig = device.get('defconfig', 'defconfig')
    arch = device.get('arch', detect_arch())
    
    tc_type = toolchain.get('type', 'clang')
    clang_prebuilt = toolchain.get('clang_prebuilt', 'proton-clang@20240901')
    gcc_prebuilt = toolchain.get('gcc_prebuilt', 'none')
    
    kernel_version = kernel.get('version', f"{detect_kernel_version()['version']}.{detect_kernel_version()['patchlevel']}")
    use_anykernel = kernel.get('anykernel', True)
    
    ksu_version = ksu.get('version', 'latest')
    ksu_integrated = ksu.get('integrated', False)
    
    branch = github_config.get('branch', 'main')
    
    # Generate workflow
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

jobs:
  build:
    runs-on: ubuntu-latest
    container: ubuntu:24.04
    
    steps:
    - name: Checkout repository
      uses: actions/checkout@v4
      with:
        fetch-depth: 0
    
    - name: Install dependencies
      run: |
        apt-get update && apt-get install -y \\
          build-essential \\
          bc \\
          binutils \\
          git \\
          curl \\
          xz-utils \\
          zip \\
          python3 \\
          python3-pip
        pip3 install pyyaml
    
    - name: Setup toolchain
      run: |
        mkdir -p toolchain
        cd toolchain
        
"""
    
    if tc_type == 'clang':
        workflow += f"""        # Download Proton Clang
        curl -sL "https://github.com/kdrag0n/proton-clang/releases/download/{clang_prebuilt}/clang.tar.zst" | tar -xJ
        echo "CLANG_PATH=$(pwd)/clang" >> $GITHUB_ENV
        echo "PATH=$(pwd)/clang/bin:$PATH" >> $GITHUB_ENV
"""
    else:
        workflow += f"""        # Download GCC
        curl -sL "https://developer.arm.com/-/media/Files/downloads/gnu/13.2.rel1/binrel/arm-gnu-toolchain-13.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz" | tar -xJ
        echo "GCC_PATH=$(pwd)/gcc" >> $GITHUB_ENV
        echo "PATH=$(pwd)/gcc/bin:$PATH" >> $GITHUB_ENV
        echo "CROSS_COMPILE=aarch64-linux-gnu-" >> $GITHUB_ENV
"""

    workflow += """
    - name: Download AnyKernel3
      if: """
    if use_anykernel:
        workflow += "true"
    else:
        workflow += "false"
    
    workflow += f"""
      run: |
        git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git anykernel3 || true
    
"""
    
    if ksu_integrated:
        workflow += """    - name: Verify KSU Integration
      run: |
        echo "Checking for KSU integration..."
        if [ -d "drivers/kernelsu" ]; then
          echo "KSU found in drivers/kernelsu/"
        else
          echo "KSU not integrated yet"
        fi
    
"""

    workflow += f"""    - name: Build kernel
      run: |
        make {defconfig} ARCH={arch}
        
        # Build with all cores
        make -j$(nproc) ARCH={arch} \\
          CC=${{CLANG_PATH:-${{GCC_PATH}}}/bin/clang \\
          CLANG_TRIPLE=aarch64-linux-gnu- \\
          CROSS_COMPILE=${{CROSS_COMPILE:-aarch64-linux-gnu-}} \\
          || make -j$(nproc) ARCH={arch}
    
"""
    
    if use_anykernel:
        workflow += """    - name: Package AnyKernel3
      run: |
        cd AnyKernel3
        # Copy kernel Image
        if [ -f ../arch/arm64/boot/Image ]; then
          cp ../arch/arm64/boot/Image .
        elif [ -f ../Image ]; then
          cp ../Image .
        fi
        
        # Copy dtbs if exists
        if [ -d ../arch/arm64/boot/dts ]; then
          mkdir -p dtbs
          cp ../arch/arm64/boot/dts/*/*.dtb dtbs/ 2>/dev/null || true
        fi
        
        # Create zip
        zip -r kernel.zip *
        
        echo "KERNEL_ZIP=kernel.zip" >> $GITHUB_ENV
    
"""
    
    workflow += """    - name: Upload artifacts
      uses: actions/upload-artifact@v4
      with:
        name: kernel-artifacts
        path: |
"""
    
    if use_anykernel:
        workflow += """          AnyKernel3/kernel.zip
"""
    
    workflow += """          arch/arm64/boot/Image
          vmlinux
          Module.symvers
        if-no-files-found: ignore

    - name: Build Summary
      run: |
        echo "## Build Summary" >> $GITHUB_STEP_SUMMARY
        echo "- Device: ${{ env.DEVICE_CODENAME }}" >> $GITHUB_STEP_SUMMARY
        echo "- Kernel: ${{ env.KERNEL_VERSION }}" >> $GITHUB_STEP_SUMMARY
        echo "- Architecture: ${{ env.ARCH }}" >> $GITHUB_STEP_SUMMARY
        echo "- Toolchain: ${{ env.TOOLCHAIN_TYPE }}" >> $GITHUB_STEP_SUMMARY
"""
    
    return workflow

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
        '-v', '--verbose',
        action='store_true',
        help='Verbose output'
    )
    
    args = parser.parse_args()
    
    print(f"{Colors.BOLD}{Colors.BLUE}========================================{Colors.NC}")
    print(f"{Colors.BOLD}{Colors.BLUE}  Kernel Workflow Generator v1.0{Colors.NC}")
    print(f"{Colors.BOLD}{Colors.BLUE}========================================{Colors.NC}")
    print()
    
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
