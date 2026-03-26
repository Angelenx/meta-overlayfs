//! 常量：KernelSU 普通模块挂载所需的路径与标记文件名。
//!
//! 本项目采用 dual-directory 架构：
//! - metadata：由普通模块安装阶段写入（包含 `disable` / `skip_mount` 等标记）
//! - content：由普通模块安装钩子归档到 ext4 镜像挂载点中（供启动阶段 overlay 挂载使用）
pub const MODULE_METADATA_DIR: &str = "/data/adb/modules/";
pub const MODULE_CONTENT_DIR: &str = "/data/adb/metamodule/mnt/";

// Legacy constant (for backwards compatibility with older scripts).
pub const _MODULE_DIR: &str = "/data/adb/modules/";

/// 禁用标记文件名：存在则不参与挂载。
pub const DISABLE_FILE_NAME: &str = "disable";
pub const _REMOVE_FILE_NAME: &str = "remove";

/// 跳过挂载标记文件名：存在则不参与挂载与 lowerdir 收集。
pub const SKIP_MOUNT_FILE_NAME: &str = "skip_mount";

/// 可写层根目录（读写 layer 的 upperdir/workdir 位于其下）。
pub const SYSTEM_RW_DIR: &str = "/data/adb/modules/.rw/";

/// overlayfs 的 `source` 字符串：用于 KernelSU 对挂载归属的识别。
pub const KSU_OVERLAY_SOURCE: &str = "KSU";
