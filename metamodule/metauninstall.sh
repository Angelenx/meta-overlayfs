#!/system/bin/sh
############################################
# mm-overlayfs metauninstall.sh
# Module uninstallation hook for ext4 image cleanup
############################################

# Constants
MNT_DIR="/data/adb/metamodule/mnt"

if [ -z "$MODULE_ID" ]; then
    echo "! Error: MODULE_ID not provided"
    exit 1
fi

echo "- Cleaning up module content from image: $MODULE_ID"

# 检查镜像是否已挂载；如果未挂载则无需清理（通常不会出现，但这里保证幂等性）。
if ! mountpoint -q "$MNT_DIR" 2>/dev/null; then
    echo "! Warning: Image not mounted, skipping cleanup"
    exit 0
fi

# 从 ext4 镜像中移除该普通模块归档的分区目录（例如 $MODULE_ID/system）。
MOD_IMG_DIR="$MNT_DIR/$MODULE_ID"
if [ -d "$MOD_IMG_DIR" ]; then
    echo "  Removing $MOD_IMG_DIR"
    rm -rf "$MOD_IMG_DIR" || {
        echo "! Warning: Failed to remove module content from image"
    }
    echo "- Module content removed from image"
else
    echo "- No module content found in image, skipping"
fi

exit 0
