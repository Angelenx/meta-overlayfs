#!/system/bin/sh
# meta-overlayfs Module Mount Handler
# This script is the entry point for dual-directory module mounting.
#
# 运行时职责：
# 1) 挂载（或确认已挂载）ext4 镜像 modules.img，得到内容根目录 MNT_DIR；
# 2) 导出给 Rust 挂载程序的环境变量：
#    - MODULE_METADATA_DIR：普通模块元数据目录（默认 /data/adb/modules）
#    - MODULE_CONTENT_DIR：普通模块内容目录（来自 ext4 镜像的 mnt 挂载点）
# 3) 执行架构相关的挂载二进制（meta-overlayfs）。

MODDIR="${0%/*}"
IMG_FILE="$MODDIR/modules.img"
MNT_DIR="$MODDIR/mnt"
RW_ROOT="/data/adb/modules/.rw"
PARTITIONS="system vendor product system_ext odm oem"

# RW_ROOT 目录约定：
# - 用户/安装脚本可手动创建：
#   /data/adb/modules/.rw/<partition>/{upperdir,workdir}
# - 若这些目录存在，本脚本会尽量对其应用与系统分区相同的 SELinux context，
#   以降低 overlayfs 挂载失败的概率。

# Log function
log() {
    echo "[meta-overlayfs] $1"
}

log "Starting module mount process"

# Ensure ext4 image is mounted
if ! mountpoint -q "$MNT_DIR" 2>/dev/null; then
    log "Image not mounted, mounting now..."

    # Check if image file exists
    if [ ! -f "$IMG_FILE" ]; then
        log "ERROR: Image file not found at $IMG_FILE"
        exit 1
    fi

    # Create mount point
    mkdir -p "$MNT_DIR"

    # Mount the ext4 image
    chcon u:object_r:ksu_file:s0 "$IMG_FILE" 2>/dev/null
    mount -t ext4 -o loop,rw,noatime "$IMG_FILE" "$MNT_DIR" || {
        log "ERROR: Failed to mount image"
        exit 1
    }
    log "Image mounted successfully at $MNT_DIR"
else
    log "Image already mounted at $MNT_DIR"
fi

# Binary path (architecture-specific binary selected during installation)
BINARY="$MODDIR/meta-overlayfs"

if [ ! -f "$BINARY" ]; then
    log "ERROR: Binary not found: $BINARY"
    exit 1
fi

# Special .rw handling
if [ -d "$RW_ROOT" ]; then
    log "Applying SELinux contexts for RW partition structures"

    for part in $PARTITIONS; do
        PART_DIR="$RW_ROOT/$part"
        REFERENCE_PATH="/$part"
        if [ -d "$PART_DIR" ] && [ -e "$REFERENCE_PATH" ]; then
            chcon --reference="$REFERENCE_PATH" "$PART_DIR" 2>/dev/null
            UPPER_DIR="$PART_DIR/upperdir"
            if [ -d "$UPPER_DIR" ]; then
                chcon --reference="$PART_DIR" "$UPPER_DIR" 2>/dev/null
            fi
            WORK_DIR="$PART_DIR/workdir"
            if [ -d "$WORK_DIR" ]; then
                chcon --reference="$PART_DIR" "$WORK_DIR" 2>/dev/null
            fi
        fi
    done
fi

# Set dual-directory environment variables
export MODULE_METADATA_DIR="/data/adb/modules"
export MODULE_CONTENT_DIR="$MNT_DIR"

log "Metadata directory: $MODULE_METADATA_DIR"
log "Content directory: $MODULE_CONTENT_DIR"
log "Executing $BINARY"

# Execute the mount binary
"$BINARY"
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    log "Mount failed with exit code $EXIT_CODE"
    exit $EXIT_CODE
fi

log "Mount completed successfully"
exit 0
