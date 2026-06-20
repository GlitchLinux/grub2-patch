#!/bin/bash
# ====================================================================
#  Grub2-Patch.sh - Patch GRUB2 with a1ive's map/wimboot support
# --------------------------------------------------------------------
#  Replaces stock GRUB2 EFI binary, BIOS core.img, and modules with
#  a1ive's patched versions, adding "map" and "wimboot" commands.
#
#  This enables:
#    UEFI:  map -f "/path/to/image.iso"   (virtual CD-ROM)
#    BIOS:  wimboot @:bcd:... @:boot.wim:...  (WinPE boot)
#           + enhanced drivemap for raw ISO/IMG boot
#
#  Usage:
#    sudo ./Grub2-Patch.sh              # interactive mode
#    sudo ./Grub2-Patch.sh /mnt/usb     # patch external drive
#    sudo ./Grub2-Patch.sh --system     # patch system GRUB directly
#    sudo ./Grub2-Patch.sh --restore    # restore original backup
#    sudo ./Grub2-Patch.sh --status     # show patch status
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

cleanup() { rm -rf "${WORK_DIR}" 2>/dev/null; }
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

extract_patch() {
    mkdir -p "${WORK_DIR}"
    tar xzf "${PATCH_TAR}" -C "${WORK_DIR}"
}

backup_file() {
    local src="$1"
    local backup="${src}${BACKUP_SUFFIX}"
    if [ ! -f "${backup}" ]; then
        cp -a "${src}" "${backup}"
        msg "Backed up: $(basename "${src}")"
    else
        info "Backup exists: $(basename "${backup}")"
    fi
}

backup_dir() {
    local src="$1"
    local backup="${src}${BACKUP_SUFFIX}"
    if [ ! -d "${backup}" ]; then
        cp -a "${src}" "${backup}"
        msg "Backed up: $(basename "${src}")/"
    else
        info "Backup exists: $(basename "${backup}")/"
    fi
}

is_patched_efi() {
    strings "$1" 2>/dev/null | grep -q "Create virtual disk"
}

is_grub_efi() {
    strings "$1" 2>/dev/null | grep -q "GRUB"
}

# --------------------------------------------------------------------
#  Find GRUB components
# --------------------------------------------------------------------

find_grub_efi() {
    local root="$1"
    local candidates=(
        "${root}/EFI/BOOT/BOOTX64.EFI"
        "${root}/EFI/BOOT/bootx64.efi"
        "${root}/EFI/BOOT/grubx64.efi"
        "${root}/EFI/debian/grubx64.efi"
        "${root}/EFI/ubuntu/grubx64.efi"
        "${root}/EFI/ubuntu/shimx64.efi"
        "${root}/EFI/fedora/grubx64.efi"
        "${root}/EFI/centos/grubx64.efi"
        "${root}/EFI/rocky/grubx64.efi"
        "${root}/EFI/almalinux/grubx64.efi"
        "${root}/EFI/opensuse/grubx64.efi"
        "${root}/EFI/arch/grubx64.efi"
        "${root}/EFI/Manjaro/grubx64.efi"
        "${root}/EFI/linuxmint/grubx64.efi"
        "${root}/EFI/pop/grubx64.efi"
        "${root}/EFI/GRUB/grubx64.efi"
    )
    for c in "${candidates[@]}"; do
        [ -f "${c}" ] && is_grub_efi "${c}" && echo "${c}"
    done
    # Broad search for any other GRUB EFI binaries
    while IFS= read -r -d '' f; do
        is_grub_efi "${f}" || continue
        local dup=0
        for c in "${candidates[@]}"; do [ "${c}" = "${f}" ] && dup=1; done
        [ "${dup}" -eq 0 ] && echo "${f}"
    done < <(find "${root}/EFI" -maxdepth 3 -iname "*.efi" -print0 2>/dev/null)
}

find_modules_dir() {
    local root="$1" arch="$2"
    local candidates=(
        "${root}/boot/grub/${arch}"
        "${root}/grub/${arch}"
        "${root}/usr/lib/grub/${arch}"
    )
    for c in "${candidates[@]}"; do
        [ -d "${c}" ] && ls "${c}"/*.mod >/dev/null 2>&1 && echo "${c}" && return 0
    done
    return 1
}

find_bios_core() {
    local root="$1"
    # On a raw disk, core.img is in the post-MBR gap (not a file)
    # But some setups have it as a file
    local candidates=(
        "${root}/boot/grub/i386-pc/core.img"
        "${root}/grub/i386-pc/core.img"
    )
    for c in "${candidates[@]}"; do
        [ -f "${c}" ] && echo "${c}" && return 0
    done
    return 1
}

# --------------------------------------------------------------------
#  Patch functions
# --------------------------------------------------------------------

patch_efi() {
    local efi_target="$1"
    local mod_dir="$2"
    local root="$3"

    extract_patch

    local patch_efi="${WORK_DIR}/EFI/BOOT/BOOTX64.EFI"
    local patch_mods="${WORK_DIR}/boot/grub/x86_64-efi"

    if [ ! -f "${patch_efi}" ]; then
        err "Patch archive missing EFI binary"
        return 1
    fi

    # Backup and replace EFI binary
    backup_file "${efi_target}"
    cp -f "${patch_efi}" "${efi_target}"
    msg "Patched EFI: ${efi_target}"

    # Patch modules
    if [ -n "${mod_dir}" ] && [ -d "${mod_dir}" ]; then
        backup_dir "${mod_dir}"
        cp -f "${patch_mods}"/*.mod "${mod_dir}/"
        cp -f "${patch_mods}"/*.lst "${mod_dir}/" 2>/dev/null || true
        msg "Patched EFI modules: ${mod_dir}/"
    else
        local new_mod_dir
        if [ -n "${root}" ]; then
            new_mod_dir="${root}/boot/grub/x86_64-efi"
        else
            new_mod_dir="$(echo "${efi_target}" | sed 's|/EFI/.*||')/boot/grub/x86_64-efi"
        fi
        mkdir -p "${new_mod_dir}"
        cp -f "${patch_mods}"/*.mod "${new_mod_dir}/"
        cp -f "${patch_mods}"/*.lst "${new_mod_dir}/" 2>/dev/null || true
        msg "Created EFI modules: ${new_mod_dir}/"
    fi
}

patch_bios() {
    local target_root="$1"
    local disk_device="$2"

    extract_patch

    local patch_core="${WORK_DIR}/boot/grub/i386-pc/core-patched.img"
    local patch_mods="${WORK_DIR}/boot/grub/i386-pc"
    local patch_boot="${WORK_DIR}/boot/grub/i386-pc/boot.img"
    local patch_mkimage="${WORK_DIR}/boot/grub/grub-mkimage"

    if [ ! -f "${patch_core}" ]; then
        err "Patch archive missing BIOS core.img"
        return 1
    fi

    # Find and patch modules directory
    local mod_dir
    mod_dir="$(find_modules_dir "${target_root}" "i386-pc")" 2>/dev/null || true

    if [ -n "${mod_dir}" ] && [ -d "${mod_dir}" ]; then
        backup_dir "${mod_dir}"
        cp -f "${patch_mods}"/*.mod "${mod_dir}/"
        cp -f "${patch_mods}"/*.lst "${mod_dir}/" 2>/dev/null || true
        # Copy boot images
        for img in boot.img diskboot.img kernel.img lnxboot.img; do
            [ -f "${patch_mods}/${img}" ] && cp -f "${patch_mods}/${img}" "${mod_dir}/"
        done
        msg "Patched BIOS modules: ${mod_dir}/"
    else
        local new_mod_dir="${target_root}/boot/grub/i386-pc"
        mkdir -p "${new_mod_dir}"
        cp -f "${patch_mods}"/*.mod "${new_mod_dir}/"
        cp -f "${patch_mods}"/*.lst "${new_mod_dir}/" 2>/dev/null || true
        for img in boot.img diskboot.img kernel.img lnxboot.img; do
            [ -f "${patch_mods}/${img}" ] && cp -f "${patch_mods}/${img}" "${new_mod_dir}/"
        done
        msg "Created BIOS modules: ${new_mod_dir}/"
        mod_dir="${new_mod_dir}"
    fi

    # Install core.img to disk if we have the disk device
    if [ -n "${disk_device}" ] && [ -b "${disk_device}" ]; then
        # Check for grub-bios-setup
        local bios_setup=""
        for tool in grub-bios-setup grub2-bios-setup; do
            command -v "${tool}" >/dev/null 2>&1 && bios_setup="${tool}" && break
        done

        if [ -n "${bios_setup}" ]; then
            info "Installing BIOS core.img to ${disk_device} via ${bios_setup}"
            # Backup MBR + post-MBR gap (first 1MB)
            local mbr_backup="${target_root}/boot/grub/mbr-gap${BACKUP_SUFFIX}"
            if [ ! -f "${mbr_backup}" ]; then
                dd if="${disk_device}" of="${mbr_backup}" bs=512 count=2048 2>/dev/null
                msg "Backed up MBR + post-MBR gap"
            fi
            # Install using grub-bios-setup
            "${bios_setup}" \
                --directory="${mod_dir}" \
                --core-image="${patch_core}" \
                "${disk_device}" 2>&1 && \
                msg "Installed BIOS core.img to ${disk_device}" || {
                    warn "grub-bios-setup failed. Manual installation needed."
                    warn "Copy core-patched.img to ${mod_dir}/core.img"
                    cp -f "${patch_core}" "${mod_dir}/core.img"
                }
        else
            warn "grub-bios-setup not found."
            echo ""
            echo "  To install BIOS patch, either:"
            echo ""
            echo "    a) Install grub-pc-bin and re-run:"
            echo "       apt install grub-pc-bin"
            echo ""
            echo "    b) Use grub-install with patched modules:"
            echo "       grub-install --target=i386-pc \\"
            echo "           --directory=${mod_dir} \\"
            echo "           --boot-directory=${target_root}/boot \\"
            echo "           ${disk_device}"
            echo ""
            # Copy core.img to modules dir for manual use
            cp -f "${patch_core}" "${mod_dir}/core.img"
            msg "Saved core.img to ${mod_dir}/core.img"
        fi
    else
        warn "No disk device specified - BIOS modules patched but core.img not installed."
        cp -f "${patch_core}" "${mod_dir}/core.img"
        info "Saved core.img to ${mod_dir}/core.img"
        echo ""
        echo "  To install manually:"
        echo "    grub-bios-setup --directory=${mod_dir} --core-image=${mod_dir}/core.img /dev/sdX"
        echo ""
    fi

    # Copy grub-mkimage for future rebuilds
    if [ -f "${patch_mkimage}" ]; then
        cp -f "${patch_mkimage}" "${target_root}/boot/grub/"
        chmod +x "${target_root}/boot/grub/grub-mkimage"
        info "Saved patched grub-mkimage to ${target_root}/boot/grub/"
    fi
}

# --------------------------------------------------------------------
#  Status display
# --------------------------------------------------------------------

show_status() {
    local f="$1"
    echo -n "    $(basename "${f}"): "
    if is_patched_efi "${f}"; then
        echo -e "${GREEN}PATCHED${NC}"
    else
        echo -e "${YELLOW}STOCK${NC}"
    fi
    [ -f "${f}${BACKUP_SUFFIX}" ] && echo "      backup: ${f}${BACKUP_SUFFIX}"
}

show_all_status() {
    echo ""
    echo -e "${BOLD}  GRUB2 Patch Status${NC}"

    # System
    if [ -d "/boot/efi/EFI" ]; then
        echo ""
        echo -e "  ${BOLD}System (/boot/efi):${NC}"
        echo "  EFI:"
        local efis
        efis="$(find_grub_efi "/boot/efi")"
        [ -n "${efis}" ] && while IFS= read -r e; do show_status "${e}"; done <<< "${efis}" || echo "    (none found)"
        echo "  BIOS:"
        local bmod
        bmod="$(find_modules_dir "/" "i386-pc")" 2>/dev/null
        if [ -n "${bmod}" ]; then
            echo -n "    i386-pc modules: "
            [ -d "${bmod}${BACKUP_SUFFIX}" ] && echo -e "${GREEN}PATCHED${NC}" || echo -e "${YELLOW}STOCK${NC}"
        else
            echo "    (none found)"
        fi
    fi

    # Removable drives
    while IFS= read -r mp; do
        [ -d "${mp}/EFI" ] || [ -d "${mp}/boot/grub" ] || continue
        echo ""
        echo -e "  ${BOLD}External (${mp}):${NC}"
        echo "  EFI:"
        local efis
        efis="$(find_grub_efi "${mp}")"
        [ -n "${efis}" ] && while IFS= read -r e; do show_status "${e}"; done <<< "${efis}" || echo "    (none found)"
        echo "  BIOS:"
        local bmod
        bmod="$(find_modules_dir "${mp}" "i386-pc")" 2>/dev/null
        if [ -n "${bmod}" ]; then
            echo -n "    i386-pc modules: "
            [ -d "${bmod}${BACKUP_SUFFIX}" ] && echo -e "${GREEN}PATCHED${NC}" || echo -e "${YELLOW}STOCK${NC}"
        else
            echo "    (none found)"
        fi
    done < <(mount | grep -E "vfat|fat32|exfat|fuseblk" | awk '{print $3}')
    echo ""
}

# --------------------------------------------------------------------
#  Restore
# --------------------------------------------------------------------

restore_backup() {
    local root="$1"
    local restored=0

    while IFS= read -r -d '' backup; do
        local original="${backup%${BACKUP_SUFFIX}}"
        cp -f "${backup}" "${original}"
        rm -f "${backup}"
        msg "Restored: ${original}"
        restored=$((restored + 1))
    done < <(find "${root}" -maxdepth 6 -name "*${BACKUP_SUFFIX}" -type f -print0 2>/dev/null)

    while IFS= read -r -d '' bdir; do
        local original="${bdir%${BACKUP_SUFFIX}}"
        [ -d "${original}" ] && rm -rf "${original}"
        mv "${bdir}" "${original}"
        msg "Restored: ${original}/"
        restored=$((restored + 1))
    done < <(find "${root}" -maxdepth 6 -name "*${BACKUP_SUFFIX}" -type d -print0 2>/dev/null)

    # Restore MBR gap if backed up
    local mbr_backup
    mbr_backup="$(find "${root}" -maxdepth 5 -name "mbr-gap${BACKUP_SUFFIX}" -type f 2>/dev/null | head -1)"
    if [ -n "${mbr_backup}" ]; then
        echo ""
        warn "MBR gap backup found: ${mbr_backup}"
        echo "  To restore BIOS boot sector, run:"
        echo "    dd if=${mbr_backup} of=/dev/sdX bs=512 count=2048"
        echo "  (replace /dev/sdX with your disk device)"
    fi

    [ "${restored}" -eq 0 ] && warn "No backups found under ${root}" || { sync; msg "Restored ${restored} item(s)"; }
}

# --------------------------------------------------------------------
#  Target patching (combines EFI + BIOS)
# --------------------------------------------------------------------

patch_target() {
    local target="$1"

    info "Scanning ${target}..."

    # Find EFI binaries
    local efi_files
    efi_files="$(find_grub_efi "${target}")"

    # Find module dirs
    local efi_mods bios_mods
    efi_mods="$(find_modules_dir "${target}" "x86_64-efi")" 2>/dev/null || true
    bios_mods="$(find_modules_dir "${target}" "i386-pc")" 2>/dev/null || true

    # Find disk device for BIOS installation
    local disk_dev=""
    local part_dev
    part_dev="$(df "${target}" 2>/dev/null | tail -1 | awk '{print $1}')"
    if [ -n "${part_dev}" ] && [ -b "${part_dev}" ]; then
        # Strip partition number to get disk device
        disk_dev="$(lsblk -ndo PKNAME "${part_dev}" 2>/dev/null)"
        [ -n "${disk_dev}" ] && disk_dev="/dev/${disk_dev}"
    fi

    # Show what we found
    echo ""
    echo -e "  ${BOLD}Detected components:${NC}"
    if [ -n "${efi_files}" ]; then
        echo "  EFI binaries:"
        while IFS= read -r e; do
            local st="STOCK"
            is_patched_efi "${e}" && st="PATCHED"
            echo -e "    ${e}  ${CYAN}[${st}]${NC}"
        done <<< "${efi_files}"
    else
        echo "  EFI binaries: (none)"
    fi
    [ -n "${efi_mods}" ] && echo "  EFI modules:  ${efi_mods}/" || echo "  EFI modules:  (will create)"
    [ -n "${bios_mods}" ] && echo "  BIOS modules: ${bios_mods}/" || echo "  BIOS modules: (will create)"
    [ -n "${disk_dev}" ] && echo "  Disk device:  ${disk_dev}" || echo "  Disk device:  (not detected)"
    echo ""

    # Ask what to patch
    local has_efi=0 has_bios=0
    [ -n "${efi_files}" ] && has_efi=1
    [ -n "${bios_mods}" ] || [ -n "${disk_dev}" ] && has_bios=1

    if [ "${has_efi}" -eq 1 ] && [ "${has_bios}" -eq 1 ]; then
        echo "  What to patch?"
        echo "    1) EFI only (UEFI boot)"
        echo "    2) BIOS only (legacy boot)"
        echo "    3) Both EFI + BIOS"
        read -rp "  Select [1-3]: " patch_choice
    elif [ "${has_efi}" -eq 1 ]; then
        patch_choice=1
        info "Only EFI components detected"
    elif [ "${has_bios}" -eq 1 ]; then
        patch_choice=2
        info "Only BIOS components detected"
    else
        err "No GRUB2 installation found at ${target}"
        exit 1
    fi

    # Confirm
    read -rp "  Proceed with patching? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    [[ "${confirm}" =~ ^[Yy] ]] || { info "Aborted"; exit 0; }

    echo ""

    case "${patch_choice}" in
        1)
            while IFS= read -r e; do
                patch_efi "${e}" "${efi_mods}" "${target}"
            done <<< "${efi_files}"
            ;;
        2)
            patch_bios "${target}" "${disk_dev}"
            ;;
        3)
            while IFS= read -r e; do
                patch_efi "${e}" "${efi_mods}" "${target}"
            done <<< "${efi_files}"
            echo ""
            patch_bios "${target}" "${disk_dev}"
            ;;
    esac

    sync
    echo ""
    msg "Patch complete."
    echo ""
    echo -e "  ${BOLD}UEFI grub.cfg usage:${NC}"
    echo -e "    ${CYAN}map -f \"/path/to/image.iso\"${NC}"
    echo ""
    echo -e "  ${BOLD}BIOS grub.cfg usage:${NC}"
    echo -e "    ${CYAN}linux16 /boot/grub/images/memdisk iso${NC}       (memdisk - loads ISO to RAM)"
    echo -e "    ${CYAN}initrd16 /path/to/image.iso${NC}"
    echo ""
    echo -e "  ${BOLD}Both BIOS+UEFI wimboot:${NC}"
    echo -e "    ${CYAN}wimboot @:bcd:(loop)/Boot/BCD @:boot.sdi:(loop)/Boot/boot.sdi @:boot.wim:(loop)/Sources/boot.wim${NC}"
    echo ""
}

# --------------------------------------------------------------------
#  Interactive mode
# --------------------------------------------------------------------

interactive_mode() {
    echo ""
    echo -e "${BOLD}  GRUB2 Patcher - a1ive map/wimboot${NC}"
    echo -e "  Adds UEFI ISO boot: ${CYAN}map -f /path/to.iso${NC}"
    echo -e "  Adds BIOS wimboot:  ${CYAN}wimboot @:boot.wim:...${NC}"
    echo ""
    echo "    1)  System GRUB  (/boot/efi + /boot/grub)"
    echo "    2)  External drive (USB/HDD)"
    echo "    3)  Custom path"
    echo "    4)  Show status"
    echo "    5)  Restore backup"
    echo "    q)  Quit"
    echo ""
    read -rp "  Select [1-5/q]: " choice

    case "${choice}" in
        1)
            local efi_mount="/boot/efi"
            if [ ! -d "${efi_mount}/EFI" ]; then
                local efi_part
                efi_part="$(lsblk -rno NAME,PARTTYPE 2>/dev/null | grep -i "c12a7328" | awk '{print $1}' | head -1)"
                if [ -n "${efi_part}" ]; then
                    mkdir -p "${efi_mount}"
                    mount "/dev/${efi_part}" "${efi_mount}" 2>/dev/null || mount "${efi_part}" "${efi_mount}" 2>/dev/null || {
                        err "Failed to mount EFI partition"; exit 1
                    }
                fi
            fi
            # For system GRUB, we patch EFI at /boot/efi and BIOS modules at /
            echo ""
            local efi_files bios_mods
            efi_files="$(find_grub_efi "${efi_mount}")"
            bios_mods="$(find_modules_dir "/" "i386-pc")" 2>/dev/null || true
            local efi_mods
            efi_mods="$(find_modules_dir "${efi_mount}" "x86_64-efi")" 2>/dev/null || \
            efi_mods="$(find_modules_dir "/" "x86_64-efi")" 2>/dev/null || true

            [ -n "${efi_files}" ] && {
                while IFS= read -r e; do
                    patch_efi "${e}" "${efi_mods}" "${efi_mount}"
                done <<< "${efi_files}"
            }
            [ -n "${bios_mods}" ] && {
                local root_disk
                root_disk="$(lsblk -ndo PKNAME "$(df / | tail -1 | awk '{print $1}')" 2>/dev/null)"
                [ -n "${root_disk}" ] && root_disk="/dev/${root_disk}"
                patch_bios "/" "${root_disk}"
            }
            sync
            msg "System GRUB patched."
            ;;
        2)
            echo ""
            echo -e "  ${BOLD}Mounted FAT/EFI partitions:${NC}"
            echo ""
            local -a mps=()
            local idx=0
            while IFS= read -r line; do
                local dev mp
                dev="$(echo "${line}" | awk '{print $1}')"
                mp="$(echo "${line}" | awk '{print $3}')"
                if [ -d "${mp}/EFI" ] || [ -d "${mp}/boot/grub" ]; then
                    idx=$((idx + 1))
                    mps+=("${mp}")
                    local label size
                    label="$(lsblk -rno LABEL "${dev}" 2>/dev/null || echo "-")"
                    size="$(lsblk -rno SIZE "${dev}" 2>/dev/null || echo "?")"
                    echo "    ${idx})  ${mp}  [${dev}]  ${size}  ${label}"
                fi
            done < <(mount | grep -E "vfat|fat32|exfat|fuseblk")
            if [ "${idx}" -eq 0 ]; then
                read -rp "  No drives found. Enter mount point: " mp
                [ -d "${mp}" ] && patch_target "${mp}" || { err "Not found"; exit 1; }
            else
                echo ""
                read -rp "  Select [1-${idx}]: " dc
                [ "${dc}" -ge 1 ] 2>/dev/null && [ "${dc}" -le "${idx}" ] && \
                    patch_target "${mps[$((dc - 1))]}" || { err "Invalid"; exit 1; }
            fi
            ;;
        3)
            read -rp "  Enter path: " p
            [ -d "${p}" ] && patch_target "${p}" || \
            [ -f "${p}" ] && { patch_efi "${p}" "" ""; } || \
            { err "Not found: ${p}"; exit 1; }
            ;;
        4) show_all_status ;;
        5)
            echo "  Restore where?"
            echo "    1) System"
            echo "    2) External drive"
            read -rp "  Select [1-2]: " rc
            case "${rc}" in
                1) restore_backup "/boot/efi"; restore_backup "/boot/grub" ;;
                2) read -rp "  Mount point: " rp; restore_backup "${rp}" ;;
            esac
            ;;
        q|Q) exit 0 ;;
        *) err "Invalid selection"; exit 1 ;;
    esac
}

# --------------------------------------------------------------------
#  Main
# --------------------------------------------------------------------

check_root "$@"
check_tar

case "${1:-}" in
    --system|-s) interactive_mode_choice=1; check_tar; interactive_mode ;;
    --restore|-r) restore_backup "${2:-/boot/efi}"; restore_backup "${2:-/boot/grub}" ;;
    --status|-S) show_all_status ;;
    --help|-h)
        echo ""
        echo "Usage: sudo $0 [OPTIONS] [MOUNTPOINT]"
        echo ""
        echo "Options:"
        echo "  (none)           Interactive mode"
        echo "  /path/to/mount   Patch GRUB2 at specified mount point"
        echo "  --system, -s     Patch system GRUB"
        echo "  --restore, -r    Restore backups (optionally specify path)"
        echo "  --status, -S     Show patch status"
        echo "  --help, -h       This help"
        echo ""
        echo "Adds a1ive's 'map' + 'wimboot' commands to GRUB2."
        echo "Originals backed up with .stock-backup suffix."
        echo ""
        ;;
    "") interactive_mode ;;
    *)
        if [ -d "$1" ]; then
            patch_target "$1"
        elif [ -f "$1" ]; then
            patch_efi "$1" "" ""
        else
            err "Invalid path: $1"
            exit 1
        fi
        ;;
esac
