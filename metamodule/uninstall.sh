#!/system/bin/sh
############################################
# meta-overlayfs uninstall.sh
#
# 元模块（metamodule）卸载阶段的清理脚本。
# 主要目标：卸载 ext4 镜像，避免残留挂载或 sysfs 状态影响后续安装/重启。
############################################

MODDIR="${0%/*}"
MNT_DIR="$MODDIR/mnt"

echo "- Uninstalling metamodule..."

# Unmount the ext4 image if mounted
if mountpoint -q "$MNT_DIR" 2>/dev/null; then
    echo "- Unmounting image..."
    umount "$MNT_DIR" 2>/dev/null || {
        echo "- Warning: Failed to unmount cleanly"
        umount -l "$MNT_DIR" 2>/dev/null
    }
    echo "- Image unmounted"
fi

echo "- Uninstall complete"

exit 0
