#!/system/bin/sh
############################################
# meta-overlayfs metainstall.sh
# Module installation hook for ext4 image support
############################################

# Constants
IMG_FILE="/data/adb/metamodule/modules.img"
MNT_DIR="/data/adb/metamodule/mnt"

# Ensure ext4 image is mounted
ensure_image_mounted() {
    if ! mountpoint -q "$MNT_DIR" 2>/dev/null; then
        ui_print "- Mounting modules image"
        mkdir -p "$MNT_DIR"
        chcon u:object_r:ksu_file:s0 "$IMG_FILE" 2>/dev/null
        mount -t ext4 -o loop,rw,noatime "$IMG_FILE" "$MNT_DIR" || {
            abort "! Failed to mount modules image"
        }
        ui_print "- Image mounted successfully"
    else
        ui_print "- Image already mounted"
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
        return 1
    fi

    if [ ! -d "$MODPATH/system" ]; then
        ui_print "- No system/ directory detected; keeping files under /data/adb/modules"
        return 1
    fi

    return 0
}

# 拷贝 SELinux 上下文。
#
# ext4 镜像内的文件会由运行时读取并参与挂载，因此需要尽量保持 SELinux context。
# 这里通过 `chcon --reference` 镜像 src 中每个条目到 dst。
copy_selinux_contexts() {
    command -v chcon >/dev/null 2>&1 || return 0

    SRC="$1"
    DST="$2"

    if [ -z "$SRC" ] || [ -z "$DST" ] || [ ! -e "$SRC" ] || [ ! -e "$DST" ]; then
        return 0
    fi

    CHCON_FLAG=""
    if [ -L "$SRC" ]; then
        CHCON_FLAG="-h"
    fi
    chcon $CHCON_FLAG --reference="$SRC" "$DST" 2>/dev/null || true

    find "$SRC" -print | while IFS= read -r PATH_SRC; do
        if [ "$PATH_SRC" = "$SRC" ]; then
            continue
        fi
        REL_PATH="${PATH_SRC#"${SRC}/"}"
        PATH_DST="$DST/$REL_PATH"
        if [ -e "$PATH_DST" ] || [ -L "$PATH_DST" ]; then
            CHCON_FLAG=""
            if [ -L "$PATH_SRC" ]; then
                CHCON_FLAG="-h"
            fi
            chcon $CHCON_FLAG --reference="$PATH_SRC" "$PATH_DST" 2>/dev/null || true
        fi
    done
}

# 安装完成后的归档步骤：把分区目录拷贝到 ext4 镜像中。
#
# 注意：当前实现使用 `cp -af`（拷贝）而不是“移动”，因此原目录仍可能保留在
# `/data/adb/modules/<module_id>/` 下（主要影响磁盘占用，不影响挂载逻辑）。
post_install_to_image() {
    ui_print "- Copying module content to image"

    set_perm "$MNT_DIR" 0 0 0755 0644

    MOD_IMG_DIR="$MNT_DIR/$MODID"
    mkdir -p "$MOD_IMG_DIR"
    set_perm "$MOD_IMG_DIR" 0 0 0755 0644

            # 拷贝该模块暴露的所有分区目录（如果存在）
    for partition in system vendor product system_ext odm oem; do
        if [ -d "$MODPATH/$partition" ]; then
            ui_print "- Copying $partition/"
            cp -af "$MODPATH/$partition" "$MOD_IMG_DIR/" || {
                ui_print "! Warning: Failed to move $partition"
                continue
            }
            copy_selinux_contexts "$MODPATH/$partition" "$MOD_IMG_DIR/$partition"
        fi
    done
}

# 当前脚本中未使用的辅助函数（保留给后续 overlay 替换/opaque 语义扩展）。
mark_replace() {
	replace_target="$1"
	mkdir -p "$replace_target"
	setfattr -n trusted.overlay.opaque -v y "$replace_target"
}

ui_print "- Using meta-overlayfs metainstall"

install_module

if module_requires_overlay_move; then
    ensure_image_mounted
    post_install_to_image
else
    ui_print "- Skipping move to modules image"
fi

ui_print "- Installation complete"
