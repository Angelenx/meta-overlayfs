#!/system/bin/sh
############################################
# meta-overlayfs metainstall.sh
# Module installation hook for ext4 image support
############################################

# 尝试使用 /tmp（通常是 tmpfs/ramdisk），如果失败则回退到 /data/local/tmp
# Try /tmp first (usually tmpfs/ramdisk), fallback to /data/local/tmp
for LOG_DIR in /tmp /data/local/tmp; do
    if [ -d "$LOG_DIR" ] && touch "$LOG_DIR/.write_test" 2>/dev/null; then
        rm -f "$LOG_DIR/.write_test"
        LOG_FILE="$LOG_DIR/metainstall-${MODID}.log"
        LOG_LOCATION="$LOG_DIR"
        break
    fi
done

# Fallback if all else fails
if [ -z "$LOG_FILE" ]; then
    LOG_FILE="/data/local/tmp/metainstall-${MODID}.log"
    LOG_LOCATION="/data/local/tmp"
fi

# 重定向所有输出到日志文件 + stdout
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== metainstall.sh START for module: $MODID ==="
echo "MODPATH=$MODPATH"
echo "MODID=$MODID"
echo "ZIPFILE=$ZIPFILE"
echo "Time: $(date)"
echo "Log location: $LOG_FILE ($LOG_LOCATION)"

# Constants
IMG_FILE="/data/adb/metamodule/modules.img"
MNT_DIR="/data/adb/metamodule/mnt"

# Log to both ui_print and kernel dmesg for debugging
log_both() {
    local msg="$1"
    ui_print "- $msg"
    echo "[meta-overlayfs-metainstall] $msg" > /dev/kmsg 2>/dev/null || true
}

# Ensure ext4 image is mounted
ensure_image_mounted() {
    if ! mountpoint -q "$MNT_DIR" 2>/dev/null; then
        ui_print "- Mounting modules image"
        log_both "Mounting modules image from $IMG_FILE"
        mkdir -p "$MNT_DIR"
        chcon u:object_r:ksu_file:s0 "$IMG_FILE" 2>/dev/null
        mount -t ext4 -o loop,rw,noatime "$IMG_FILE" "$MNT_DIR" || {
            abort "! Failed to mount modules image"
        }
        ui_print "- Image mounted successfully"
        log_both "Image mounted successfully at $MNT_DIR"
    else
        ui_print "- Image already mounted"
        log_both "Image already mounted at $MNT_DIR"
    fi
}

# 判断该普通模块是否需要把 payload 归档到 ext4 镜像中。
#
# 该项目的挂载 lowerdir 来自 ext4 镜像中的内容，因此：
# - 有 `skip_mount`：完全不参与挂载（且不会归档到镜像）
# - 没有 `system/` 目录：大概率不需要做分区挂载（这里选择不归档）
module_requires_overlay_move() {
    if [ -f "$MODPATH/skip_mount" ]; then
        ui_print "- skip_mount flag detected; keeping files under /data/adb/modules"
        log_both "Module $MODID: skip_mount flag detected"
        return 1
    fi

    if [ ! -d "$MODPATH/system" ]; then
        ui_print "- No system/ directory detected; keeping files under /data/adb/modules"
        log_both "Module $MODID: No system/ directory detected"
        return 1
    fi

    log_both "Module $MODID: found system/ directory, will move to image"
    return 0
}

# 从系统实际分区路径获取 SELinux context 并应用到镜像中的文件。
#
# 之前的实现是从模块源文件（zip 解压产物）复制 context，但那些 context 可能不正确。
# 改进：以系统中对应路径的 context 为准（例如 /odm/etc/ 的 context 从真正的 /odm/etc/ 获取），
# 这样 overlayfs 的 lowerdir 文件就和系统分区保持完全一致，避免 tag mismatch。
#
# 参数：
#   $1 = partition name (e.g., "system", "vendor", "odm")
#   $2 = destination directory in image (e.g., /data/adb/metamodule/mnt/<module_id>/odm)
apply_selinux_contexts() {
    command -v chcon >/dev/null 2>&1 || return 0

    PARTITION="$1"
    DST="$2"

    if [ -z "$PARTITION" ] || [ -z "$DST" ] || [ ! -e "$DST" ]; then
        return 0
    fi

    # 系统中对应分区的根路径
    SYSTEM_REF="/$PARTITION"
    if [ ! -d "$SYSTEM_REF" ]; then
        log_both "  SELinux: system reference $SYSTEM_REF not found, skipping"
        return 0
    fi

    log_both "  SELinux: applying contexts from $SYSTEM_REF to $DST"

    # 先设置根目录的 context
    chcon --reference="$SYSTEM_REF" "$DST" 2>/dev/null || true

    # 递归遍历目标目录中的每个文件/目录
    find "$DST" -print | while IFS= read -r DST_PATH; do
        [ "$DST_PATH" = "$DST" ] && continue

        # 计算相对路径
        REL_PATH="${DST_PATH#"${DST}/"}"

        # 系统中对应的路径
        REF_PATH="$SYSTEM_REF/$REL_PATH"

        if [ -e "$REF_PATH" ] || [ -L "$REF_PATH" ]; then
            # 系统中存在对应文件，直接从系统获取 context
            CHCON_FLAG=""
            [ -L "$DST_PATH" ] && CHCON_FLAG="-h"
            chcon $CHCON_FLAG --reference="$REF_PATH" "$DST_PATH" 2>/dev/null || true
        elif [ -e "$DST_PATH" ]; then
            # 系统中不存在（模块新增的文件），使用父目录的 context
            PARENT_REL=$(dirname "$REL_PATH")
            PARENT_REF="$SYSTEM_REF/$PARENT_REL"
            if [ -d "$PARENT_REF" ]; then
                CHCON_FLAG=""
                [ -L "$DST_PATH" ] && CHCON_FLAG="-h"
                chcon $CHCON_FLAG --reference="$PARENT_REF" "$DST_PATH" 2>/dev/null || true
            fi
        fi
    done

    log_both "  SELinux: contexts applied for $PARTITION"
}

# 安装完成后的归档步骤：把分区目录拷贝到 ext4 镜像中。
#
# 注意：当前实现使用 `cp -af`（拷贝）而不是“移动”，因此原目录仍可能保留在
# `/data/adb/modules/<module_id>/` 下（主要影响磁盘占用，不影响挂载逻辑）。
post_install_to_image() {
    ui_print "- Copying module content to image"
    log_both "Copying module $MODID content to image"

    chmod 0755 "$MNT_DIR"
    chown 0:0 "$MNT_DIR"

    MOD_IMG_DIR="$MNT_DIR/$MODID"
    mkdir -p "$MOD_IMG_DIR"
    chmod 0755 "$MOD_IMG_DIR"
    chown 0:0 "$MOD_IMG_DIR"

    # 拷贝该模块暴露的所有分区目录（如果存在）
    for partition in system vendor product system_ext odm oem; do
        if [ -d "$MODPATH/$partition" ]; then
            ui_print "- Copying $partition/"
            log_both "Module $MODID: Copying $partition/ to $MOD_IMG_DIR/"
            cp -af "$MODPATH/$partition" "$MOD_IMG_DIR/" || {
                ui_print "! Warning: Failed to copy $partition"
                log_both "Module $MODID: Warning - Failed to copy $partition, continuing..."
                continue
            }
            log_both "Module $MODID: Successfully copied $partition, applying SELinux contexts"
            apply_selinux_contexts "$partition" "$MOD_IMG_DIR/$partition"
        fi
    done
    log_both "Module $MODID: Finished copying all partitions to image"
}

# 当前脚本中未使用的辅助函数（保留给后续 overlay 替换/opaque 语义扩展）。
mark_replace() {
	replace_target="$1"
	mkdir -p "$replace_target"
	setfattr -n trusted.overlay.opaque -v y "$replace_target"
}

ui_print "- Using meta-overlayfs metainstall"
log_both "=== meta-overlayfs metainstall starting for module $MODID ==="

install_module

if module_requires_overlay_move; then
    ensure_image_mounted
    post_install_to_image
else
    ui_print "- Skipping move to modules image"
    log_both "Module $MODID: Skipping move to modules image"
fi

ui_print "- Installation complete"
log_both "=== meta-overlayfs metainstall completed for module $MODID ==="
echo "=== metainstall.sh END for module: $MODID ==="
echo "Log file: $LOG_FILE"
