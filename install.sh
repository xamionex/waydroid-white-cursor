#!/bin/bash
# Встроить белый курсор в system.img Waydroid / Bake the white cursor into Waydroid's system.img
#   sudo bash install.sh            — с копией образа system.img.before-white-cursor
#   sudo bash install.sh remove     — вернуть копию
# Закройте игры: сессия Waydroid будет остановлена. / Waydroid session will be stopped.

set -Eeuo pipefail

cd "$(dirname "$0")"

# Locate system.img
IMG=""
SEARCH_PATHS=(
    /var/lib/waydroid/images/system.img
    /usr/share/waydroid-extra/images/system.img
    /usr/share/waydroid/images/system.img
    /etc/waydroid/images/system.img
    /opt/waydroid/images/system.img
)

for path in "${SEARCH_PATHS[@]}"; do
    if [ -f "$path" ]; then
        IMG="$path"
        break
    fi
done

if [ -z "$IMG" ]; then
    echo "ERROR: Could not find Waydroid system.img"
    printf '  %s\n' "${SEARCH_PATHS[@]}"
    exit 1
fi

echo "Using image: $IMG"

BAK=$IMG.before-white-cursor
APK=build/WhiteCursor.apk
[ -f "$APK" ] || APK=prebuilt/WhiteCursor.apk

DIR=/system/product/overlay/WhiteCursor
EXTRA_SIZE=$((1024 * 1024 * 1024))

# Stop Waydroid
waydroid session stop 2>/dev/null || true
systemctl stop waydroid-container

# Restore backup
if [ "${1:-}" = remove ]; then
    if [ ! -f "$BAK" ]; then
        echo "ERROR: No backup found: $BAK"
        systemctl start waydroid-container
        exit 1
    fi

    cp --reflink=auto "$BAK" "$IMG"
    systemctl start waydroid-container

    echo "Reverted / Откат сделан"
    exit 0
fi

# Check APK
if [ ! -f "$APK" ]; then
    echo "ERROR: WhiteCursor.apk not found"
    systemctl start waydroid-container
    exit 1
fi

# Create backup only once
if [ ! -f "$BAK" ]; then
    echo "Creating backup..."
    cp --reflink=auto "$IMG" "$BAK"
fi

# Image size + 1 GiB
IMG_SIZE=$(stat -c %s "$IMG")
LOOP_SIZE=$((IMG_SIZE + EXTRA_SIZE))

echo "Image size: $((IMG_SIZE / 1024 / 1024)) MiB"
echo "Extra size: 1024 MiB"
echo "New size:   $((LOOP_SIZE / 1024 / 1024)) MiB"

M=$(mktemp -d)
LOOP=""

cleanup() {
    mountpoint -q "$M" && umount "$M" || true
    if [ -n "$LOOP" ]; then
        losetup -d "$LOOP" || true
    fi
    rmdir "$M" 2>/dev/null || true
}

restart_waydroid() {
    systemctl start waydroid-container || true
}

trap 'cleanup; restart_waydroid' EXIT

# Expand image file
truncate -s "$LOOP_SIZE" "$IMG"

# Attach loop device
LOOP=$(losetup --find --show "$IMG")

# Detect filesystem
FS=$(blkid -p -o value -s TYPE "$LOOP")

echo "Filesystem: $FS"

case "$FS" in
    ext4)
        echo "Checking filesystem..."
        e2fsck -fy "$LOOP"

        echo "Resizing filesystem..."
        resize2fs "$LOOP"
        ;;
    *)
        echo "ERROR: Unsupported filesystem: $FS"
        exit 1
        ;;
esac

# Mount and install overlay
mount -o rw "$LOOP" "$M"

mkdir -p "$M$DIR"
install -m 644 "$APK" "$M$DIR/WhiteCursor.apk"
chmod 755 "$M$DIR"

# Unmount and detach
cleanup
LOOP=""
M=""

trap restart_waydroid EXIT

systemctl start waydroid-container
trap - EXIT

echo "Done! Start Waydroid."
echo "Image: $IMG"
echo "Backup: $BAK"
