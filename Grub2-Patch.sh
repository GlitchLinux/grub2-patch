#!/bin/bash
# ====================================================================
#  Grub2-Patch.sh - Patch GRUB2 with a1ive's map/wimboot support
# --------------------------------------------------------------------
#  Replaces stock GRUB2 EFI binary and x86_64-efi modules with
#  a1ive's patched versions, adding the "map" and "wimboot" commands.
#
#  This enables UEFI ISO booting via:
#    map -f "/path/to/image.iso"
#
#  Supports:
#    - System GRUB (installed on /boot/efi)
#    - External USB/drive (any mounted FAT32 EFI partition)
#    - Auto-detection of EFI binary and module locations
#
#  Usage:
#    sudo ./Grub2-Patch.sh              # interactive mode
#    sudo ./Grub2-Patch.sh /mnt/usb     # patch external drive
#    sudo ./Grub2-Patch.sh --system     # patch system GRUB directly
#    sudo ./Grub2-Patch.sh --restore    # restore original backup
#
#  Source: https://github.com/GlitchLinux/grub2-patch
#  Based on: https://github.com/a1ive/grub (GPLv3)
# ====================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_TAR="${SCRIPT_DIR}/grub-patch.tar.gz"
WORK_DIR="/tmp/grub2-patch-$$"
BACKUP_SUFFIX=".stock-backup"

# --------------------------------------------------------------------
#  Helper functions
# --------------------------------------------------------------------

msg()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }

cleanup() {
    rm -rf "${WORK_DIR}" 2>/dev/null
}
trap cleanup EXIT

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "This script must be run as root."
        echo "    sudo $0 $*"
        exit 1
    fi
}

check_tar() {
    if [ ! -f "${PATCH_TAR}" ]; then
        err "Patch archive not found: ${PATCH_TAR}"
        echo "    Make sure grub-patch.tar.gz is in the same directory as this script."
        exit 1
    fi
}

# Find all EFI binaries that are GRUB2
find_grub_efi() {
    local search_root="$1"
    local found=()

    # Common EFI binary locations
    local candidates=(
        "${search_root}/EFI/BOOT/BOOTX64.EFI"
        "${search_root}/EFI/BOOT/bootx64.efi"
        "${search_root}/EFI/BOOT/grubx64.efi"
        "${search_root}/EFI/debian/grubx64.efi"
        "${search_root}/EFI/ubuntu/grubx64.efi"
        "${search_root}/EFI/fedora/grubx64.efi"
        "${search_root}/EFI/centos/grubx64.efi"
        "${search_root}/EFI/rocky/grubx64.efi"
        "${search_root}/EFI/almalinux/grubx64.efi"
        "${search_root}/EFI/opensuse/grubx64.efi"
        "${search_root}/EFI/arch/grubx64.efi"
        "${search_root}/EFI/Manjaro/grubx64.efi"
        "${search_root}/EFI/linuxmint/grubx64.efi"
        "${search_root}/EFI/pop/grubx64.efi"
        "${search_root}/EFI/zorin/grubx64.efi"
        "${search_root}/EFI/GRUB/grubx64.efi"
    )

    for candidate in "${candidates[@]}"; do
        if [ -f "${candidate}" ]; then
            # Verify it's actually a GRUB2 binary
            if strings "${candidate}" 2>/dev/null | grep -q "GRUB" ; then
                found+=("${candidate}")
            fi
        fi
    done

    # Also do a broad search for any grub EFI binary
    while IFS= read -r -d '' f; do
        if strings "${f}" 2>/dev/null | grep -q "GRUB" ; then
            # Avoid duplicates
            local dup=0
            for existing in "${found[@]}"; do
                [ "${existing}" = "${f}" ] && dup=1 && break
            done
            [ "${dup}" -eq 0 ] && found+=("${f}")
        fi
    done < <(find "${search_root}/EFI" -maxdepth 3 -iname "*.efi" -print0 2>/dev/null)

    printf '%s\n' "${found[@]}"
}

# Find the x86_64-efi modules directory
find_modules_dir() {
    local search_root="$1"
    local candidates=(
        "${search_root}/boot/grub/x86_64-efi"
        "${search_root}/grub/x86_64-efi"
        "${search_root}/usr/lib/grub/x86_64-efi"
    )
    for candidate in "${candidates[@]}"; do
        if [ -d "${candidate}" ] && ls "${candidate}"/*.mod >/dev/null 2>&1; then
            echo "${candidate}"
            return 0
        fi
    done
    return 1
}

# Check if GRUB is already patched
is_patched() {
    local efi_file="$1"
    if strings "${efi_file}" 2>/dev/null | grep -q "Create virtual disk" ; then
        return 0
    fi
    return 1
}

# Backup a file
backup_file() {
    local src="$1"
    local backup="${src}${BACKUP_SUFFIX}"
    if [ ! -f "${backup}" ]; then
        cp -a "${src}" "${backup}"
        msg "Backed up: $(basename "${src}") -> $(basename "${backup}")"
    else
        info "Backup already exists: $(basename "${backup}")"
    fi
}

# Backup a directory
backup_dir() {
    local src="$1"
    local backup="${src}${BACKUP_SUFFIX}"
    if [ ! -d "${backup}" ]; then
        cp -a "${src}" "${backup}"
        msg "Backed up modules directory"
    else
        info "Module backup already exists"
    fi
}

# Apply the patch to a target
apply_patch() {
    local efi_target="$1"
    local mod_target="$2"

    # Extract patch files
    mkdir -p "${WORK_DIR}"
    tar xzf "${PATCH_TAR}" -C "${WORK_DIR}"

    local patch_efi="${WORK_DIR}/EFI/BOOT/BOOTX64.EFI"
    local patch_mods="${WORK_DIR}/boot/grub/x86_64-efi"

    if [ ! -f "${patch_efi}" ]; then
        err "Patch archive is missing EFI binary"
        exit 1
    fi
    if [ ! -d "${patch_mods}" ]; then
        err "Patch archive is missing x86_64-efi modules"
        exit 1
    fi

    # Verify the patch binary has map support
    if ! strings "${patch_efi}" | grep -q "Create virtual disk" ; then
        err "Patch EFI binary does not contain map module - archive may be corrupt"
        exit 1
    fi

    # Backup originals
    backup_file "${efi_target}"
    if [ -n "${mod_target}" ] && [ -d "${mod_target}" ]; then
        backup_dir "${mod_target}"
    fi

    # Apply EFI binary
    cp -f "${patch_efi}" "${efi_target}"
    msg "Patched: ${efi_target}"

    # Apply modules
    if [ -n "${mod_target}" ] && [ -d "${mod_target}" ]; then
        cp -f "${patch_mods}"/*.mod "${mod_target}/"
        # Copy .lst files if they exist
        cp -f "${patch_mods}"/*.lst "${mod_target}/" 2>/dev/null || true
        msg "Patched: ${mod_target}/ ($(ls "${patch_mods}"/*.mod | wc -l) modules)"
    else
        warn "No existing modules directory found - creating one"
        local efi_dir
        efi_dir="$(dirname "$(dirname "${efi_target}")")"
        local new_mod_dir="${efi_dir}/../boot/grub/x86_64-efi"
        # If the target is on an EFI partition, put modules relative to it
        if echo "${efi_target}" | grep -qi "EFI/BOOT"; then
            local mount_root
            mount_root="$(echo "${efi_target}" | sed 's|/EFI/.*||')"
            new_mod_dir="${mount_root}/boot/grub/x86_64-efi"
        fi
        mkdir -p "${new_mod_dir}"
        cp -f "${patch_mods}"/*.mod "${new_mod_dir}/"
        cp -f "${patch_mods}"/*.lst "${new_mod_dir}/" 2>/dev/null || true
        msg "Created: ${new_mod_dir}/ ($(ls "${patch_mods}"/*.mod | wc -l) modules)"
    fi

    sync
    msg "Patch applied successfully"
}

# Restore from backup
restore_backup() {
    local search_root="$1"

    local restored=0

    # Find and restore EFI backups
    while IFS= read -r -d '' backup; do
        local original="${backup%${BACKUP_SUFFIX}}"
        cp -f "${backup}" "${original}"
        rm -f "${backup}"
        msg "Restored: ${original}"
        restored=$((restored + 1))
    done < <(find "${search_root}" -maxdepth 5 -name "*${BACKUP_SUFFIX}" -type f -print0 2>/dev/null)

    # Find and restore module directory backups
    while IFS= read -r -d '' backup_dir_path; do
        local original_dir="${backup_dir_path%${BACKUP_SUFFIX}}"
        if [ -d "${original_dir}" ]; then
            rm -rf "${original_dir}"
        fi
        mv "${backup_dir_path}" "${original_dir}"
        msg "Restored modules: ${original_dir}"
        restored=$((restored + 1))
    done < <(find "${search_root}" -maxdepth 5 -name "*${BACKUP_SUFFIX}" -type d -print0 2>/dev/null)

    if [ "${restored}" -eq 0 ]; then
        warn "No backups found to restore under ${search_root}"
    else
        sync
        msg "Restored ${restored} item(s)"
    fi
}

# Display patch status
show_status() {
    local efi_file="$1"
    echo ""
    echo -e "  ${BOLD}File:${NC}    ${efi_file}"
    echo -n "  Status:  "
    if is_patched "${efi_file}"; then
        echo -e "${GREEN}PATCHED${NC} (map + wimboot available)"
    else
        echo -e "${YELLOW}STOCK${NC} (no map/wimboot support)"
    fi
    local backup="${efi_file}${BACKUP_SUFFIX}"
    if [ -f "${backup}" ]; then
        echo -e "  ${BOLD}Backup:${NC}  ${backup}"
    fi
}

# --------------------------------------------------------------------
#  Mode: Interactive selection
# --------------------------------------------------------------------

interactive_mode() {
    echo ""
    echo -e "${BOLD}  GRUB2 Patcher - a1ive map/wimboot module${NC}"
    echo -e "  Adds UEFI ISO boot support via: ${CYAN}map -f /path/to.iso${NC}"
    echo ""
    echo "  What do you want to patch?"
    echo ""
    echo "    1)  System GRUB  (/boot/efi)"
    echo "    2)  External drive (USB/HDD)"
    echo "    3)  Custom path"
    echo "    4)  Show current status"
    echo "    5)  Restore original backup"
    echo "    q)  Quit"
    echo ""
    read -rp "  Select [1-5/q]: " choice

    case "${choice}" in
        1)
            patch_system
            ;;
        2)
            select_external_drive
            ;;
        3)
            read -rp "  Enter mount point or EFI path: " custom_path
            if [ -f "${custom_path}" ]; then
                # Direct EFI file path
                local mod_dir
                mod_dir="$(find_modules_dir "$(dirname "$(dirname "$(dirname "${custom_path}")")")")" 2>/dev/null || true
                apply_patch "${custom_path}" "${mod_dir}"
            elif [ -d "${custom_path}" ]; then
                patch_target "${custom_path}"
            else
                err "Path not found: ${custom_path}"
                exit 1
            fi
            ;;
        4)
            show_all_status
            ;;
        5)
            echo ""
            echo "  Restore where?"
            echo "    1) System (/boot/efi)"
            echo "    2) External drive"
            read -rp "  Select [1-2]: " restore_choice
            case "${restore_choice}" in
                1) restore_backup "/boot/efi" ;;
                2)
                    read -rp "  Enter mount point: " restore_path
                    restore_backup "${restore_path}"
                    ;;
            esac
            ;;
        q|Q)
            exit 0
            ;;
        *)
            err "Invalid selection"
            exit 1
            ;;
    esac
}

# Show status for all detected GRUB installations
show_all_status() {
    echo ""
    echo -e "${BOLD}  GRUB2 EFI Status:${NC}"

    # System
    if [ -d "/boot/efi/EFI" ]; then
        local system_efis
        system_efis="$(find_grub_efi "/boot/efi")"
        if [ -n "${system_efis}" ]; then
            echo ""
            echo -e "  ${BOLD}System (/boot/efi):${NC}"
            while IFS= read -r efi; do
                show_status "${efi}"
            done <<< "${system_efis}"
        fi
    fi

    # Check mounted removable drives
    while IFS= read -r mountpoint; do
        if [ -d "${mountpoint}/EFI" ]; then
            local ext_efis
            ext_efis="$(find_grub_efi "${mountpoint}")"
            if [ -n "${ext_efis}" ]; then
                echo ""
                echo -e "  ${BOLD}External (${mountpoint}):${NC}"
                while IFS= read -r efi; do
                    show_status "${efi}"
                done <<< "${ext_efis}"
            fi
        fi
    done < <(mount | grep -E "vfat|fat32|exfat" | awk '{print $3}')
    echo ""
}

# Patch system GRUB
patch_system() {
    local efi_mount="/boot/efi"

    if [ ! -d "${efi_mount}/EFI" ]; then
        # Try to find and mount EFI partition
        local efi_part
        efi_part="$(lsblk -rno NAME,PARTTYPE 2>/dev/null | grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" | awk '{print $1}' | head -1)"
        if [ -z "${efi_part}" ]; then
            efi_part="$(fdisk -l 2>/dev/null | grep "EFI System" | awk '{print $1}' | head -1)"
        fi
        if [ -n "${efi_part}" ]; then
            warn "EFI partition not mounted, mounting ${efi_part} to ${efi_mount}"
            mkdir -p "${efi_mount}"
            mount "${efi_part}" "${efi_mount}" || {
                # Try /dev/ prefix
                mount "/dev/${efi_part}" "${efi_mount}" 2>/dev/null || {
                    err "Failed to mount EFI partition"
                    exit 1
                }
            }
        else
            err "Cannot find EFI partition. Is this a UEFI system?"
            exit 1
        fi
    fi

    patch_target "${efi_mount}"
}

# Select and patch an external drive
select_external_drive() {
    echo ""
    echo -e "  ${BOLD}Detected FAT/EFI partitions:${NC}"
    echo ""

    local -a mount_points=()
    local idx=0

    while IFS= read -r line; do
        local dev mp
        dev="$(echo "${line}" | awk '{print $1}')"
        mp="$(echo "${line}" | awk '{print $3}')"
        if [ -d "${mp}/EFI" ] || [ -d "${mp}/boot/grub" ]; then
            idx=$((idx + 1))
            mount_points+=("${mp}")
            local label
            label="$(lsblk -rno LABEL "${dev}" 2>/dev/null || echo "?")"
            local size
            size="$(lsblk -rno SIZE "${dev}" 2>/dev/null || echo "?")"
            echo "    ${idx})  ${mp}  [${dev}]  ${size}  ${label}"
        fi
    done < <(mount | grep -E "vfat|fat32|exfat|fuseblk")

    if [ "${idx}" -eq 0 ]; then
        warn "No mounted FAT32/EFI drives detected."
        read -rp "  Enter mount point manually: " manual_mp
        if [ -d "${manual_mp}" ]; then
            patch_target "${manual_mp}"
        else
            err "Path not found"
            exit 1
        fi
        return
    fi

    echo ""
    read -rp "  Select drive [1-${idx}]: " drive_choice
    if [ "${drive_choice}" -ge 1 ] 2>/dev/null && [ "${drive_choice}" -le "${idx}" ]; then
        patch_target "${mount_points[$((drive_choice - 1))]}"
    else
        err "Invalid selection"
        exit 1
    fi
}

# Patch a target mount point
patch_target() {
    local target="$1"

    info "Scanning ${target} for GRUB2 EFI binaries..."

    local efi_files
    efi_files="$(find_grub_efi "${target}")"

    if [ -z "${efi_files}" ]; then
        err "No GRUB2 EFI binaries found under ${target}/EFI/"
        exit 1
    fi

    # Find modules directory
    local mod_dir
    mod_dir="$(find_modules_dir "${target}")" 2>/dev/null || true

    echo ""
    echo -e "  ${BOLD}Found GRUB2 EFI binaries:${NC}"
    local -a efi_array=()
    local idx=0
    while IFS= read -r efi; do
        idx=$((idx + 1))
        efi_array+=("${efi}")
        local patched_status
        if is_patched "${efi}"; then
            patched_status="${GREEN}[patched]${NC}"
        else
            patched_status="${YELLOW}[stock]${NC}"
        fi
        echo -e "    ${idx})  ${efi}  ${patched_status}"
    done <<< "${efi_files}"

    if [ -n "${mod_dir}" ]; then
        echo ""
        info "Modules directory: ${mod_dir}"
    fi

    echo ""
    if [ "${idx}" -eq 1 ]; then
        read -rp "  Patch this binary? [Y/n]: " confirm
        confirm="${confirm:-Y}"
        if [[ "${confirm}" =~ ^[Yy] ]]; then
            apply_patch "${efi_array[0]}" "${mod_dir}"
        else
            info "Aborted"
        fi
    else
        echo "    a)  Patch ALL"
        read -rp "  Select [1-${idx}/a]: " efi_choice
        if [ "${efi_choice}" = "a" ] || [ "${efi_choice}" = "A" ]; then
            for efi in "${efi_array[@]}"; do
                apply_patch "${efi}" "${mod_dir}"
            done
        elif [ "${efi_choice}" -ge 1 ] 2>/dev/null && [ "${efi_choice}" -le "${idx}" ]; then
            apply_patch "${efi_array[$((efi_choice - 1))]}" "${mod_dir}"
        else
            err "Invalid selection"
            exit 1
        fi
    fi

    echo ""
    echo -e "  ${BOLD}Verification:${NC}"
    for efi in "${efi_array[@]}"; do
        if [ -f "${efi}" ]; then
            show_status "${efi}"
        fi
    done
    echo ""
    msg "Done. The 'map' and 'wimboot' commands are now available in GRUB2 EFI."
    echo ""
    echo -e "  ${BOLD}Usage in grub.cfg:${NC}"
    echo -e "    ${CYAN}map -f \"/path/to/image.iso\"${NC}          # boot ISO as virtual CD"
    echo -e "    ${CYAN}map -f -m \"/path/to/image.iso\"${NC}       # copy ISO to RAM first"
    echo ""
}

# --------------------------------------------------------------------
#  Main
# --------------------------------------------------------------------

check_root "$@"
check_tar

case "${1:-}" in
    --system|-s)
        patch_system
        ;;
    --restore|-r)
        target="${2:-/boot/efi}"
        restore_backup "${target}"
        ;;
    --status|-S)
        show_all_status
        ;;
    --help|-h)
        echo ""
        echo "Usage: sudo $0 [OPTIONS] [MOUNTPOINT]"
        echo ""
        echo "Options:"
        echo "  (none)           Interactive mode"
        echo "  /path/to/mount   Patch GRUB2 on the specified mount point"
        echo "  --system, -s     Patch system GRUB directly"
        echo "  --restore, -r    Restore original backups"
        echo "  --status, -S     Show patch status of all detected GRUB2 installs"
        echo "  --help, -h       Show this help"
        echo ""
        echo "What this does:"
        echo "  Replaces your GRUB2 EFI binary and x86_64-efi modules with"
        echo "  a1ive's patched versions (from github.com/a1ive/grub)."
        echo "  This adds the 'map' command for UEFI virtual disk boot and"
        echo "  the 'wimboot' command for WinPE/WIM boot support."
        echo ""
        echo "  Original files are backed up with a .stock-backup suffix."
        echo "  Use --restore to revert to the originals."
        echo ""
        ;;
    "")
        interactive_mode
        ;;
    *)
        if [ -d "$1" ]; then
            patch_target "$1"
        elif [ -f "$1" ]; then
            mod_dir="$(find_modules_dir "$(dirname "$(dirname "$(dirname "$1")")")")" 2>/dev/null || true
            apply_patch "$1" "${mod_dir}"
        else
            err "Not a valid path: $1"
            echo "    Use --help for usage information"
            exit 1
        fi
        ;;
esac
