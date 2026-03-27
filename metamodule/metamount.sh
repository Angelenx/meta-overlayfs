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

# Log function: both stdout and kernel dmesg
log() {
    echo "[meta-overlayfs] $1"
    echo "[meta-overlayfs] $1" > /dev/kmsg 2>/dev/null || true
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
    if ! mount -t ext4 -o loop,rw,noatime "$IMG_FILE" "$MNT_DIR"; then
        log "ERROR: Failed to mount image at $MNT_DIR (check dmesg for details)"
        exit 1
    fi
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

# 动态迁移逻辑: 兼容非 KSU 标准安装 (如 Scene) 或手动修改
log "Checking for un-migrated or modified module content..."

for mod_dir in /data/adb/modules/*; do
    [ -d "$mod_dir" ] || continue
    mod_id=$(basename "$mod_dir")
    
    # 忽略元模块自身和特殊目录
    [ "$mod_id" = "meta-overlayfs" ] && continue
    [ "$mod_id" = ".rw" ] && continue
    
    # 检查模块是否启用了
    [ -f "$mod_dir/disable" ] && continue
    
    # 检查模块中是否有需要同步的分区目录，或者是否需要清理镜像中多余的分区
    needs_migration=false
    for part in $PARTITIONS; do
        # 1. 外部有内容，需要同步进去 (无条件同步)
        if [ -d "$mod_dir/$part" ]; then
            needs_migration=true
            break
        fi
        # 2. 外部删除了分区目录，但镜像里还有，需要清理镜像
        if [ ! -d "$mod_dir/$part" ] && [ -d "$MNT_DIR/$mod_id/$part" ]; then
            needs_migration=true
            break
        fi
    done
    
    if [ "$needs_migration" = "true" ]; then
        log "Module $mod_id needs synchronization with image..."
        
        # 确保目标目录存在
        mkdir -p "$MNT_DIR/$mod_id"
        
        for part in $PARTITIONS; do
            # 场景 A: 外部目录不存在，但镜像里有 -> 用户删除了外部目录，我们要同步删除镜像里的
            if [ ! -d "$mod_dir/$part" ] && [ -d "$MNT_DIR/$mod_id/$part" ]; then
                log "  Removing $mod_id/$part from image (deleted externally)..."
                rm -rf "$MNT_DIR/$mod_id/$part"
                continue
            fi

            # 场景 B: 外部目录存在，每次开机都强制同步
            if [ -d "$mod_dir/$part" ]; then
                log "  Syncing $mod_id/$part to image..."
                
                # 先清空镜像中旧的对应目录，确保完全以外部为准（处理用户删除子文件的情况）
                rm -rf "$MNT_DIR/$mod_id/$part"
                
                # 使用 cp -a 同步内容到 ext4 镜像，保留外部源文件
                cp -a "$mod_dir/$part" "$MNT_DIR/$mod_id/"
                
                # 修复 SELinux contexts
                REFERENCE_PATH="/$part"
                if [ -e "$REFERENCE_PATH" ]; then
                    log "  Applying SELinux contexts from $REFERENCE_PATH to $MNT_DIR/$mod_id/$part"
                    chcon -R --reference="$REFERENCE_PATH" "$MNT_DIR/$mod_id/$part" 2>/dev/null
                fi
            fi
        done
        log "Module $mod_id synchronization complete."
    fi
done

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

# 挂载成功后，更新 module.prop 的 description 以显示当前生效的模块
log "Updating module.prop description..."
PROP_FILE="$MODDIR/module.prop"
if [ -f "$PROP_FILE" ]; then
    # 收集已挂载的模块列表 (存在于 MNT_DIR 且没有 disable 标记的模块)
    MOUNTED_MODULES=""
    for mod in "$MNT_DIR"/*; do
        [ -d "$mod" ] || continue
        mod_id=$(basename "$mod")
        # 排除系统目录
        [ "$mod_id" = "lost+found" ] && continue
        
        # 检查是否被禁用
        if [ ! -f "/data/adb/modules/$mod_id/disable" ]; then
            if [ -z "$MOUNTED_MODULES" ]; then
                MOUNTED_MODULES="$mod_id"
            else
                MOUNTED_MODULES="$MOUNTED_MODULES, $mod_id"
            fi
        fi
    done
    
    # 构造新的描述信息
    if [ -z "$MOUNTED_MODULES" ]; then
        DESC="Running [Active: None]"
    else
        DESC="Running [Active: $MOUNTED_MODULES]"
    fi
    
    # 替换 module.prop 中的 description 行
    sed -i "s/^description=.*/description=$DESC/" "$PROP_FILE"
    log "Updated description: $DESC"
fi

log "Mount completed successfully"
exit 0
