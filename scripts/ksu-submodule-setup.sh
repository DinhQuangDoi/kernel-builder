#!/bin/bash
# ksu-submodule-setup.sh - Register ReSukiSU as a git submodule + create drivers/kernelsu symlink
# Version: 1.0.0
#
# ReSukiSU Kbuild (drivers/kernelsu/Kbuild) REQUIRES a real git submodule:
# it runs `git rev-list --count HEAD` for the KSU version and refuses to build
# if it detects the source was copied / inlined (no .git). This script wires up
# the correct integration so the GitHub Actions build passes.
#
# Usage:
#   ./kernel-builder/scripts/ksu-submodule-setup.sh            # add submodule + symlink
#   ./kernel-builder/scripts/ksu-submodule-setup.sh --cleanup  # remove symlink + deinit submodule

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

SUB_URL="https://github.com/ReSukiSU/ReSukiSU.git"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  ReSukiSU Git Submodule Setup${NC}"
echo -e "${BLUE}========================================${NC}"

# Run from the kernel source root (where .git and drivers/ live).
if [ ! -d drivers ]; then
    echo -e "${RED}[ERROR] drivers/ not found. Run this from the kernel source root.${NC}" >&2
    exit 127
fi

if [ ! -d .git ] && [ ! -f .git ]; then
    echo -e "${YELLOW}[WARN] Not a git repo (no .git). ReSukiSU Kbuild needs a submodule,"
    echo -e "  so the kernel should be a git repo for CI builds."
    echo -e "  Contining with a plain clone may fail on the submodule check.${NC}"
fi

if [ "$1" = "--cleanup" ]; then
    echo -e "[+] Cleaning up..."
    [ -L drivers/kernelsu ] && rm drivers/kernelsu && echo -e "${GREEN}[-] Symlink drivers/kernelsu removed.${NC}"
    if git submodule status KernelSU >/dev/null 2>&1; then
        git submodule deinit -f KernelSU 2>/dev/null && echo -e "${GREEN}[-] Submodule KernelSU deinitialized.${NC}" || true
    fi
    echo -e "${BLUE}Done.${NC}"
    exit 0
fi

# 1) Register submodule if missing
if git submodule status KernelSU >/dev/null 2>&1; then
    echo -e "${GREEN}[i] KernelSU is already a registered git submodule.${NC}"
else
    if [ -d KernelSU ]; then
        # Remove a previously inlined/copied KernelSU (would shadow the submodule).
        if [ -d KernelSU/.git ] || [ -f KernelSU/.git ]; then
            echo -e "${YELLOW}[i] Found existing KernelSU dir with its own .git.${NC}"
        else
            echo -e "${YELLOW}[i] Found copied-in KernelSU without .git -> removing so the"
            echo -e "${YELLOW}    submodule can be registered (Kbuild rejects copied code).${NC}"
        fi
        rm -rf KernelSU
    fi
    echo -e "[+] Registering ReSukiSU as git submodule..."
    git submodule add "$SUB_URL" KernelSU
    echo -e "${GREEN}[+] Submodule KernelSU added.${NC}"
fi

# 2) Create drivers/kernelsu symlink
if [ ! -L drivers/kernelsu ]; then
    ln -sfn "$(realpath --relative-to=drivers KernelSU/kernel)" drivers/kernelsu
    echo -e "${GREEN}[+] Symlink drivers/kernelsu -> KernelSU/kernel created.${NC}"
else
    echo -e "${GREEN}[i] Symlink drivers/kernelsu already present.${NC}"
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Setup complete. Commit with:${NC}"
echo "  git add .gitmodules KernelSU drivers/kernelsu"
echo "  git commit -m \"Integrate ReSukiSU as submodule\""
echo "  git push"
echo -e "${BLUE}CI checkout must use: submodules: recursive (kernel-builder does automatomatically).${NC}"