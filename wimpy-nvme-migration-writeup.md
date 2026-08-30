Wimpy Btrfs/NVMe Storage Migration
==================================

!!! WARNING — READ BEFORE RUNNING !!!
This procedure contains destructive storage commands. In particular, `btrfs replace start` overwrites the specified target partition. Do not copy these commands blindly. First run the inspection commands, verify the actual device names, UUIDs, PARTUUIDs, mount points, Btrfs device ID, and Limine options on the target system. Confirm that the target partition contains no data that must be preserved and obtain explicit approval immediately before the overwrite. Keep the old drive untouched until the new drive has independently booted and passed all post-boot checks. If any command reports an unexpected device, mount, error, or boot configuration, STOP.

Date
----
29-30 August 2026, based on command output captured during the migration.

Objective
---------
Migrate the running CachyOS installation on wimpy from the old 1.8 TB NVMe to the new 4 TB NVMe, preserving the existing Btrfs subvolume layout, filesystem UUID, and Limine UEFI boot setup. The old drive was retained during the migration and remains available for rollback.

Host and boot configuration
---------------------------
Host: wimpy
Boot mode: UEFI
Bootloader: Limine 12.6.1
Secure Boot: disabled
systemd-boot: not installed

Before migration
----------------
Old system drive: /dev/nvme0n1
  /dev/nvme0n1p1  4G   vfat   UUID=F21C-9BBF
                    PARTUUID=976f9477-6309-4ae6-abd7-5deeabfc7b52
                    mounted at /boot
  /dev/nvme0n1p2  1.8T btrfs UUID=d3757335-ed3a-4340-9956-0d9412afce70
                    mounted at /
  /dev/nvme0n1p3  32G  swap   UUID=8ca0f602-7c9f-48ef-bd8d-417dc926d473

New system drive: /dev/nvme1n1
  /dev/nvme1n1p1  4G   vfat   UUID=2B31-2F72
                    PARTUUID=a987de99-9aa8-4f16-8812-9f38d2d78f49
  /dev/nvme1n1p2  32G  swap   UUID=0435ed16-bcb3-4647-93ff-c14deff6cba4
  /dev/nvme1n1p3  3.7T btrfs (disposable filesystem before migration)
                    PARTUUID=af172d2d-8907-4769-a186-598d6c6b4796

The target ESP was not mounted initially. The running system used zram swap and also had the old swap partition enabled; no swap migration was required.

Btrfs layout before migration
-----------------------------
Filesystem UUID: d3757335-ed3a-4340-9956-0d9412afce70
Initial device: devid 1, /dev/nvme0n1p2
Initial filesystem size: 1.78 TiB
Filesystem data: approximately 1.49 TiB
Initial free space: approximately 291 GiB

Subvolumes preserved:
  /@       -> /
  /@home  -> /home
  /@root  -> /root
  /@srv   -> /srv
  /@cache -> /var/cache
  /@tmp   -> /var/tmp
  /@log   -> /var/log

Preparation and safeguards
--------------------------
The target /dev/nvme1n1p3 was explicitly confirmed disposable before overwrite. The old drive was not erased, reformatted, or removed. No dd, mkfs, wipefs, partition recreation, grub-install, update-grub, or bootctl install operation was used.

Limine tooling was inspected before installation:
  /usr/bin/limine-install
  /usr/bin/limine-update
  /usr/bin/limine-entry-tool

limine-install supported --fallback and the ESP_PATH environment variable.

Btrfs device replacement
------------------------
The replacement was started with:

  sudo btrfs replace start -B 1 /dev/nvme1n1p3 /

The replacement was later run with -f from the local terminal after confirmation. Final status:

  Started on 29.Aug 20:21:23, finished on 29.Aug 20:34:31,
  0 write errs, 0 uncorr. read errs

The resulting filesystem remained UUID d3757335-ed3a-4340-9956-0d9412afce70 and used device ID 1 at /dev/nvme1n1p3. The old Btrfs device was no longer listed as active.

Filesystem expansion
--------------------
Command:

  sudo btrfs filesystem resize max /

Result:
  Device size:       3.69 TiB
  Device allocated:  1.52 TiB
  Device unallocated: 2.17 TiB
  Used:              1.50 TiB
  Free estimated:    2.19 TiB
  df size:            3.7T
  df available:       2.2T
  df usage:           41%

ESP migration
-------------
The old /boot contents were synchronized to /dev/nvme1n1p1 while it was mounted at /mnt/new-boot using rsync with preservation and deletion enabled:

  sudo rsync -aHAX --delete /boot/ /mnt/new-boot/

Verification found the required files on the new ESP, including:
  /EFI/limine/limine_x64.efi
  /limine.conf
  kernel and initramfs files for CachyOS, CachyOS LTS, and CachyOS RC

Limine was installed to the new ESP with:

  sudo env ESP_PATH=/mnt/new-boot limine-install --fallback

The command completed successfully.

UEFI registration
-----------------
A separate firmware entry was created, preserving the old entries:

  sudo efibootmgr -c -d /dev/nvme1n1 -p 1 \
    -L 'Limine-new' -l '\\EFI\\limine\\limine_x64.efi'

The new entry was:

  Boot0003* Limine-new
  HD(1,GPT,a987de99-9aa8-4f16-8812-9f38d2d78f49,...)
  \\EFI\\limine\\limine_x64.efi

The old Limine and UEFI OS entries were retained as fallback. The resulting boot order placed Boot0003 first.

/etc/fstab change
-----------------
Only the /boot UUID was changed. A backup was created first:

  /etc/fstab.before-nvme-migration

Old entry:
  UUID=F21C-9BBF  /boot  vfat  defaults,umask=0077 0 2

Final entry:
  UUID=2B31-2F72  /boot  vfat  defaults,umask=0077 0 2

The seven Btrfs entries continued to reference the original filesystem UUID. No swap entry was added.

Post-reboot independent verification
-------------------------------------
The system was rebooted with the new entry first. Final output showed:

  BootCurrent: 0003
  BootOrder: 0003,0004,0000,0001,0002

This proves the running system booted through Boot0003, Limine-new, on the new ESP.

Final mounts:
  /      -> /dev/nvme1n1p3[/@]
  /boot  -> /dev/nvme1n1p1

Final Btrfs state:
  UUID: d3757335-ed3a-4340-9956-0d9412afce70
  devid 1: /dev/nvme1n1p3
  size: 3.69 TiB
  used: 1.52 TiB device / 1.49 TiB filesystem data

Final filesystem report:
  /dev/nvme1n1p3 btrfs 3.7T 1.5T 2.2T 41% /

The old NVMe remained present but was not mounted. Its old ESP, Btrfs partition, and swap partition were still visible but were not active. The new drive is therefore independently bootable and is the active system drive.

Current device summary
----------------------
  /dev/nvme1n1p1  vfat   UUID=2B31-2F72       /boot
  /dev/nvme1n1p2  swap   UUID=0435ed16-bcb3-4647-93ff-c14deff6cba4
  /dev/nvme1n1p3  btrfs  UUID=d3757335-ed3a-4340-9956-0d9412afce70  /

  /dev/nvme0n1p1  vfat   UUID=F21C-9BBF       not mounted
  /dev/nvme0n1p2  old Btrfs partition       not mounted
  /dev/nvme0n1p3  swap   UUID=8ca0f602-7c9f-48ef-bd8d-417dc926d473  not active

Post-migration recommendations
------------------------------
1. Keep the old NVMe untouched until all rollback concerns are resolved.
2. Maintain the fstab backup until the new installation has operated normally for a reasonable period.
3. If the old drive is removed, confirm the firmware still selects Boot0003 or the new NVMe's Limine entry.
4. Do not repurpose or erase the old disk until any needed data, snapshots, and recovery requirements have been checked.
5. If desired later, remove obsolete old-disk EFI entries only after confirming the new disk remains bootable; this is optional and was intentionally not done during migration.

Reproduction procedure
----------------------
This is the command sequence used for a future migration with the same layout. Device names, UUIDs, PARTUUIDs, filesystem sizes, and Limine behavior must be re-inspected rather than assumed. Do not run the destructive replacement until the target device has been independently confirmed disposable and explicit approval has been obtained.

1. Inspect the live system and prerequisites:

  lsblk -e7 -o NAME,SIZE,FSTYPE,UUID,PARTUUID,MOUNTPOINTS
  blkid
  btrfs filesystem show /
  findmnt /
  findmnt /boot
  findmnt /mnt/new-boot || true
  command -v limine-install
  limine-install --help
  command -v limine-update
  command -v limine-entry-tool
  df -hT / /boot
  btrfs filesystem usage /
  swapon --show
  zramctl
  efibootmgr -v
  grep -v '^[[:space:]]*#' /etc/fstab

2. Confirm the target Btrfs partition and target ESP. For this migration they were /dev/nvme1n1p3 and /dev/nvme1n1p1. Confirm the target contains no needed data. Record the current Btrfs device ID; it was 1.

3. Replace the Btrfs device. This overwrites the target filesystem:

  sudo btrfs replace start -B 1 /dev/nvme1n1p3 /

If the tool reports that a force option is required, use the exact approved command:

  sudo btrfs replace start -B 1 /dev/nvme1n1p3 / -f

Wait for completion and check:

  sudo btrfs replace status /
  sudo btrfs filesystem show /

Do not continue if replacement reports errors.

4. Expand the replacement filesystem:

  sudo btrfs filesystem resize max /
  sudo btrfs filesystem usage /
  df -hT /

5. Copy the old ESP to a temporary mount. The mount command is required; it was implicit in the postmortem but is included here for reproducibility:

  sudo mkdir -p /mnt/new-boot
  sudo mount /dev/nvme1n1p1 /mnt/new-boot
  sudo rsync -aHAX --delete /boot/ /mnt/new-boot/
  sudo find /mnt/new-boot -maxdepth 3 -type f -printf '%M %u:%g %s %p\\n' | sort
  sudo test -f /mnt/new-boot/EFI/limine/limine_x64.efi
  sudo test -f /mnt/new-boot/limine.conf
  findmnt /mnt/new-boot

6. Install Limine to the new ESP using the installed command's verified help:

  sudo env ESP_PATH=/mnt/new-boot limine-install --fallback

7. Create a new EFI entry while retaining old entries. Substitute the verified target disk, partition, label, and EFI path:

  sudo efibootmgr -c -d /dev/nvme1n1 -p 1 \\
    -L 'Limine-new' -l '\\EFI\\limine\\limine_x64.efi'
  sudo efibootmgr -v

8. Change only the /boot UUID, preserving a rollback copy of fstab:

  sudo cp -a /etc/fstab /etc/fstab.before-nvme-migration
  sudo sed -i 's/UUID=F21C-9BBF[[:space:]]\\+\\/boot/UUID=2B31-2F72          \\/boot/' /etc/fstab
  sudo systemctl daemon-reload
  sudo umount /mnt/new-boot
  sudo umount /boot
  sudo mount /boot
  sudo mount -a
  findmnt /boot
  grep -E '^[^#].*[[:space:]]/boot[[:space:]]' /etc/fstab

If an unmount reports busy, stop and investigate; do not force it.

9. Perform the complete pre-reboot verification:

  findmnt /
  findmnt /boot
  sudo btrfs filesystem show /
  sudo btrfs replace status /
  sudo btrfs filesystem usage /
  sudo test -f /boot/EFI/limine/limine_x64.efi
  sudo test -f /boot/limine.conf
  sudo find /boot -maxdepth 3 -type f \\
    \( -name 'vmlinuz' -o -name 'initramfs' \) -printf '%p\\n' | sort
  grep -E '^[^#].*[[:space:]]/boot[[:space:]]' /etc/fstab
  sudo efibootmgr -v
  df -hT /

10. Reboot only after saving the output and confirming that the new EFI entry is first. Prefer physically disconnecting or disabling the old NVMe for the first boot. Otherwise select the new entry in firmware. After booting, verify independently:

  findmnt /
  findmnt /boot
  sudo btrfs filesystem show /
  lsblk -e7 -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINTS
  sudo efibootmgr -v
  df -hT /

Expected post-boot sources are /dev/nvme1n1p3 for / and /dev/nvme1n1p1 for /boot. Keep the old disk untouched until this verification succeeds.

Conclusion
----------
The migration completed successfully. The CachyOS installation now runs from the 4 TB NVMe, retains its original Btrfs filesystem UUID and subvolume layout, uses the expanded 3.69 TiB Btrfs capacity, mounts /boot from the new ESP, and has been independently booted through the new Limine EFI entry. The old 1.8 TB NVMe remains preserved as a fallback.
