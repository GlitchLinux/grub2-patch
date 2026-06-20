# GRUB2 Patch - UEFI ISO Boot Support

Patches stock GRUB2 with [a1ive's](https://github.com/a1ive/grub) `map` and `wimboot` modules, enabling direct ISO boot in UEFI mode.

## What it does

Standard GRUB2 cannot boot ISO files in UEFI mode. The `loopback` device is a GRUB-internal abstraction that disappears when control is handed to an EFI binary, and `memdisk` is BIOS-only. This is why tools like Ventoy and grubfm ship their own patched GRUB2 builds.

This patcher replaces your GRUB2 EFI binary and modules with a1ive's patched versions, adding two commands:

- **`map`** - registers an ISO/IMG/VHD as a virtual block device with the UEFI firmware
- **`wimboot`** - boots WinPE WIM files directly with BCD patching

## Usage

```bash
# Clone
git clone https://github.com/GlitchLinux/grub2-patch.git
cd grub2-patch

# Interactive mode
sudo ./Grub2-Patch.sh

# Patch system GRUB directly
sudo ./Grub2-Patch.sh --system

# Patch external USB drive
sudo ./Grub2-Patch.sh /mnt/usb

# Check status
sudo ./Grub2-Patch.sh --status

# Restore originals
sudo ./Grub2-Patch.sh --restore
```

## GRUB2 config examples

### Boot a WinPE ISO in UEFI mode
```
menuentry "DiskGenius [UEFI]" {
    map -f "/boot/grub/winpe-iso/DiskGenius_v9.iso"
}
```

### Boot ISO with RAM copy (slower start, faster runtime)
```
menuentry "WinPE in RAM [UEFI]" {
    map -f -m "/path/to/winpe.iso"
}
```

### Boot a Linux live ISO
```
menuentry "Ubuntu Live [UEFI]" {
    map -f "/iso/ubuntu-24.04-desktop-amd64.iso"
}
```

### Dual BIOS/UEFI entry
```
if [ "${grub_platform}" = "efi" ]; then
    menuentry "WinPE [UEFI]" {
        map -f "/images/winpe.iso"
    }
else
    menuentry "WinPE [BIOS]" {
        linux16 /boot/grub/images/memdisk iso
        initrd16 /images/winpe.iso
    }
fi
```

### WinPE via wimboot (extracts boot.wim from ISO)
```
menuentry "WinPE wimboot [UEFI]" {
    loopback loop /images/winpe.iso
    wimboot \
        @:bootmgfw.efi:(loop)/EFI/Boot/Bootx64.efi \
        @:bcd:(loop)/EFI/Microsoft/Boot/BCD \
        @:boot.sdi:(loop)/Boot/boot.sdi \
        @:boot.wim:(loop)/Sources/boot.wim
}
```

## map command reference

```
map [OPTIONS] FILE [DISK_NAME]

Options:
  -f, --first     Set as first boot drive
  -m, --mem       Copy file to RAM before mapping
  -l, --blocklist Convert to blocklist
  -t, --type      Disk type: CD, HD, or FD
  -o, --ro        Read-only mode
  -n, --nb        Map without auto-booting
  -e, --eltorito  Also mount El Torito EFI image
  -x, --unmap     Unmap a virtual disk
```

## What gets patched

| File | Description |
|------|-------------|
| `EFI/BOOT/BOOTX64.EFI` | GRUB2 EFI binary (replaced with a1ive's build) |
| `boot/grub/x86_64-efi/*.mod` | GRUB2 modules (317 total, includes map.mod + wimboot.mod) |

Original files are backed up with a `.stock-backup` suffix. Use `--restore` to revert.

## How it works

1. The patcher finds your GRUB2 EFI binary (auto-detects distro-specific paths)
2. Backs up the original binary and modules
3. Replaces them with a1ive's patched versions
4. The new binary uses the same `/boot/grub/grub.cfg` - all your existing config works unchanged

The patched GRUB2 has `map.mod` and `wimboot.mod` built into the core EFI binary. The embedded config uses `search --file --set=root /boot/grub/grub.cfg` to find your config on any partition, making it work for both system installs and external USB drives.

## Requirements

- x86_64 UEFI system
- GRUB2 as bootloader
- FAT32 EFI System Partition
- Root privileges

## Credits

- [a1ive/grub](https://github.com/a1ive/grub) - patched GRUB2 with map/wimboot (GPLv3)
- [a1ive/grub2-filemanager](https://github.com/a1ive/grub2-filemanager) - grubfm
- [iPXE wimboot](https://ipxe.org/wimboot) - original wimboot project

## License

GPLv3 (inherits from GRUB2 and a1ive's patches)
