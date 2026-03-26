//! Dual-directory metamodule mount handler.
//!
//! `metamodule/metamount.sh` 会在启动期间执行本二进制，并通过环境变量将：
//! - metadata 目录（默认 `/data/adb/modules/`）
//! - content 目录（默认 `/data/adb/metamodule/mnt/`，ext4 镜像挂载点）
//! 传给 Rust。
//!
//! 本实现的目标是：
//! 1) 扫描 enabled 的普通模块；
//! 2) 从 content 中收集对应分区目录作为 overlayfs 的 lowerdir；
//! 3) 在系统分区目录（`/system`、`/vendor` 等）上挂载 overlayfs；
//! 4) 同时对分区下的既有子挂载点做一定的协调，尽量减少破坏。
//!
//! 关键约束：overlayfs 的 `source` 必须设置为 `"KSU"`，以便 KernelSU 正确识别并在卸载/协调时处理这些挂载。

use anyhow::{Context, Result, bail};
use log::{info, warn};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use procfs::process::Process;
use rustix::{fd::AsFd, fs::CWD, mount::*};

use crate::defs::{DISABLE_FILE_NAME, KSU_OVERLAY_SOURCE, SKIP_MOUNT_FILE_NAME, SYSTEM_RW_DIR};

/// 挂载 overlayfs。
///
/// - `lower_dirs`：普通模块在 content 目录中的对应分区目录列表（例如多个模块的 `.../system`）。
/// - `lowest`：stock 根目录（通常是调用者当前的分区挂载点或其相对路径）。
/// - `upperdir/workdir`：可选读写层路径；若路径存在则启用 overlayfs 读写模式。
/// - `dest`：挂载点（例如 `/system` 或某个 child mountpoint）。
///
/// 备注：为了支持 `mount_overlay()` 中的“先切换 cwd，再挂载子目录”的协调策略，
/// 该函数会把 `lowest` 直接拼入 `lowerdir=`，允许它是相对路径。
pub fn mount_overlayfs(
    lower_dirs: &[String],
    lowest: &str,
    upperdir: Option<PathBuf>,
    workdir: Option<PathBuf>,
    dest: impl AsRef<Path>,
) -> Result<()> {
    let lowerdir_config = lower_dirs
        .iter()
        .map(|s| s.as_ref())
        .chain(std::iter::once(lowest))
        .collect::<Vec<_>>()
        .join(":");
    info!(
        "mount overlayfs on {:?}, lowerdir={}, upperdir={:?}, workdir={:?}",
        dest.as_ref(),
        lowerdir_config,
        upperdir,
        workdir
    );

    let upperdir = upperdir
        .filter(|up| up.exists())
        .map(|e| e.display().to_string());
    let workdir = workdir
        .filter(|wd| wd.exists())
        .map(|e| e.display().to_string());

    let result = (|| {
        let fs = fsopen("overlay", FsOpenFlags::FSOPEN_CLOEXEC)?;
        let fs = fs.as_fd();
        fsconfig_set_string(fs, "lowerdir", &lowerdir_config)?;
        if let (Some(upperdir), Some(workdir)) = (&upperdir, &workdir) {
            fsconfig_set_string(fs, "upperdir", upperdir)?;
            fsconfig_set_string(fs, "workdir", workdir)?;
        }
        fsconfig_set_string(fs, "source", KSU_OVERLAY_SOURCE)?;
        fsconfig_create(fs)?;
        let mount = fsmount(fs, FsMountFlags::FSMOUNT_CLOEXEC, MountAttrFlags::empty())?;
        move_mount(
            mount.as_fd(),
            "",
            CWD,
            dest.as_ref(),
            MoveMountFlags::MOVE_MOUNT_F_EMPTY_PATH,
        )
    })();

    if let Err(e) = result {
        warn!("fsopen mount failed: {e:#}, fallback to mount");
        let mut data = format!("lowerdir={lowerdir_config}");
        if let (Some(upperdir), Some(workdir)) = (upperdir, workdir) {
            data = format!("{data},upperdir={upperdir},workdir={workdir}");
        }
        mount(
            KSU_OVERLAY_SOURCE,
            dest.as_ref(),
            "overlay",
            MountFlags::empty(),
            data,
        )?;
    }
    Ok(())
}

/// 递归 bind-mount（等价于把 stock 目录原样暴露到挂载点）。
///
/// 当某个 child mountpoint 下 stock 存在但 enabled 模块没有覆盖对应相对路径时，
/// 会回退到这种策略，以避免 overlayfs 覆盖破坏已有挂载结构。
pub fn bind_mount(from: impl AsRef<Path>, to: impl AsRef<Path>) -> Result<()> {
    info!(
        "bind mount {} -> {}",
        from.as_ref().display(),
        to.as_ref().display()
    );
    let tree = open_tree(
        CWD,
        from.as_ref(),
        OpenTreeFlags::OPEN_TREE_CLOEXEC
            | OpenTreeFlags::OPEN_TREE_CLONE
            | OpenTreeFlags::AT_RECURSIVE,
    )?;
    move_mount(
        tree.as_fd(),
        "",
        CWD,
        to.as_ref(),
        MoveMountFlags::MOVE_MOUNT_F_EMPTY_PATH,
    )?;
    Ok(())
}

/// 针对某个 child mountpoint 进行 overlay/bind 协调。
///
/// - `mount_point`：要挂载的点（绝对路径）
/// - `relative`：`mount_point` 相对当前分区根目录的路径片段（例如 `"/etc"`）
/// - `module_roots`：各 enabled 模块在 content 中的“分区根目录列表”（例如 `.../system`）
/// - `stock_root`：stock 的对应目录（可能是相对路径，依赖上层的 cwd）
fn mount_overlay_child(
    mount_point: &str,
    relative: &String,
    module_roots: &Vec<String>,
    stock_root: &String,
) -> Result<()> {
    if !module_roots
        .iter()
        .any(|lower| Path::new(&format!("{lower}{relative}")).exists())
    {
        return bind_mount(stock_root, mount_point);
    }
    if !Path::new(&stock_root).is_dir() {
        return Ok(());
    }
    let mut lower_dirs: Vec<String> = vec![];
    for lower in module_roots {
        let lower_dir = format!("{lower}{relative}");
        let path = Path::new(&lower_dir);
        if path.is_dir() {
            lower_dirs.push(lower_dir);
        } else if path.exists() {
            // stock root has been blocked by this file
            return Ok(());
        }
    }
    if lower_dirs.is_empty() {
        return Ok(());
    }
    // merge modules and stock
    if let Err(e) = mount_overlayfs(&lower_dirs, stock_root, None, None, mount_point) {
        warn!("failed: {e:#}, fallback to bind mount");
        bind_mount(stock_root, mount_point)?;
    }
    Ok(())
}

/// 挂载整个分区根目录的 overlay，并协调该分区下已存在的子挂载点。
///
/// 调用者会在进入该函数时把 `root`（例如 `/system`）作为参数传入。
/// 本函数会：
/// 1) `chdir(root)`，使后续对子路径的解析尽可能在同一上下文下完成；
/// 2) 先挂载 root 的 overlay；
/// 3) 遍历 `/proc/self/mountinfo` 中该分区下已有的 mountpoint，
///    对每个 child 决定 overlay 或 bind。
pub fn mount_overlay(
    root: &String,
    module_roots: &Vec<String>,
    workdir: Option<PathBuf>,
    upperdir: Option<PathBuf>,
) -> Result<()> {
    info!("mount overlay for {root}");
    std::env::set_current_dir(root).with_context(|| format!("failed to chdir to {root}"))?;
    let stock_root = ".";

    // collect child mounts before mounting the root
    let mounts = Process::myself()?
        .mountinfo()
        .with_context(|| "get mountinfo")?;
    let mut mount_seq = mounts
        .0
        .iter()
        .filter(|m| {
            m.mount_point.starts_with(root) && !Path::new(&root).starts_with(&m.mount_point)
        })
        .map(|m| m.mount_point.to_str())
        .collect::<Vec<_>>();
    mount_seq.sort();
    mount_seq.dedup();

    mount_overlayfs(module_roots, root, upperdir, workdir, root)
        .with_context(|| "mount overlayfs for root failed")?;
    for mount_point in mount_seq.iter() {
        let Some(mount_point) = mount_point else {
            continue;
        };
        let relative = mount_point.replacen(root, "", 1);
        let stock_root: String = format!("{stock_root}{relative}");
        if !Path::new(&stock_root).exists() {
            continue;
        }
        if let Err(e) = mount_overlay_child(mount_point, &relative, module_roots, &stock_root) {
            warn!("failed to mount overlay for child {mount_point}: {e:#}, revert");
            umount_dir(root).with_context(|| format!("failed to revert {root}"))?;
            bail!(e);
        }
    }
    Ok(())
}

/// 卸载给定目录对应的挂载点。
pub fn umount_dir(src: impl AsRef<Path>) -> Result<()> {
    unmount(src.as_ref(), UnmountFlags::empty())
        .with_context(|| format!("Failed to umount {}", src.as_ref().display()))?;
    Ok(())
}

// ========== Mount coordination logic (from init_event.rs) ==========

/// 挂载某个分区（`system`/`vendor`/...）。
///
/// - 若 `/system` 等目录是 symlink，则跳过对其的 overlay（避免覆盖掉指向关系）。
/// - 若存在 `/data/adb/modules/.rw/<partition>/{upperdir,workdir}`，则启用可写层。
fn mount_partition(partition_name: &str, lowerdir: &Vec<String>) -> Result<()> {
    if lowerdir.is_empty() {
        warn!("partition: {partition_name} lowerdir is empty");
        return Ok(());
    }

    let partition = format!("/{partition_name}");

    // if /partition is a symlink and linked to /system/partition, then we don't need to overlay it separately
    if Path::new(&partition).read_link().is_ok() {
        warn!("partition: {partition} is a symlink");
        return Ok(());
    }

    let mut workdir = None;
    let mut upperdir = None;
    let system_rw_dir = Path::new(SYSTEM_RW_DIR);
    if system_rw_dir.exists() {
        workdir = Some(system_rw_dir.join(partition_name).join("workdir"));
        upperdir = Some(system_rw_dir.join(partition_name).join("upperdir"));
    }

    mount_overlay(&partition, lowerdir, workdir, upperdir)
}

/// Collect enabled module IDs from metadata directory
///
/// Reads module list and status from metadata directory, returns enabled module IDs
///
/// 规则：
/// - `disable` 存在：禁用
/// - `skip_mount` 存在：跳过挂载
/// - `module.prop` 缺失：跳过（但保留 `.rw` 目录自身）
fn collect_enabled_modules(metadata_dir: &str) -> Result<Vec<String>> {
    let dir = std::fs::read_dir(metadata_dir)
        .with_context(|| format!("Failed to read metadata directory: {}", metadata_dir))?;

    let mut enabled = Vec::new();

    for entry in dir.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }

        let module_id = match entry.file_name().to_str() {
            Some(id) => id.to_string(),
            None => continue,
        };

        // Check status markers
        if path.join(DISABLE_FILE_NAME).exists() {
            info!("Module {} disabled (has disable marker)", module_id);
            continue;
        }

        if path.join(SKIP_MOUNT_FILE_NAME).exists() {
            info!("Module {} skip_mount (has skip_mount marker)", module_id);
            continue;
        }

        // Optional: verify module.prop exists
        if !path.join("module.prop").exists() && !path.eq(Path::new(SYSTEM_RW_DIR)) {
            warn!("Module {} no module.prop, skipping", module_id);
            continue;
        }

        info!("Module {} enabled", module_id);
        enabled.push(module_id);
    }

    Ok(enabled)
}

/// Dual-directory version of mount_modules_systemlessly
///
/// Parameters:
/// - metadata_dir: Metadata directory, stores module.prop, disable, skip_mount, etc.
/// - content_dir: Content directory, stores system/, vendor/ and other partition content (ext4 image mount point)
///
/// 逻辑：
/// 1) 扫描 enabled 模块；
/// 2) 从 content 中读取每个模块对应分区目录作为 lowerdir；
/// 3) 对 `/system` 以及其它分区分别执行 overlay 挂载。
pub fn mount_modules_systemlessly(metadata_dir: &str, content_dir: &str) -> Result<()> {
    info!("=== mount_modules_systemlessly START ===");
    info!("Metadata: {}", metadata_dir);
    info!("Content: {}", content_dir);

    // 1. Traverse metadata directory, collect enabled module IDs
    let enabled_modules = collect_enabled_modules(metadata_dir)?;

    if enabled_modules.is_empty() {
        info!("No enabled modules found");
        info!("=== mount_modules_systemlessly END (no modules) ===");
        return Ok(());
    }

    info!("Found {} enabled module(s): {:?}", enabled_modules.len(), enabled_modules);

    // 2. Initialize partition lowerdir lists
    let partition = vec!["vendor", "product", "system_ext", "odm", "oem"];
    let mut system_lowerdir: Vec<String> = Vec::new();
    let mut partition_lowerdir: HashMap<String, Vec<String>> = HashMap::new();

    for part in &partition {
        partition_lowerdir.insert((*part).to_string(), Vec::new());
    }

    // 3. Read module content from content directory
    for module_id in &enabled_modules {
        let module_content_path = Path::new(content_dir).join(module_id);

        if !module_content_path.exists() {
            warn!("Module {} has no content directory at {}, skipping", module_id, module_content_path.display());
            continue;
        }

        info!("Processing module: {}", module_id);

        // Collect system partition
        let system_path = module_content_path.join("system");
        if system_path.is_dir() {
            system_lowerdir.push(system_path.display().to_string());
            info!("  + system/ found for {}", module_id);
        }

        // Collect other partitions
        for part in &partition {
            let part_path = module_content_path.join(part);
            if part_path.is_dir()
                && let Some(v) = partition_lowerdir.get_mut(*part)
            {
                v.push(part_path.display().to_string());
                info!("  + {}/ found for {}", part, module_id);
            }
        }
    }

    // 4. Mount partitions
    info!("=== Mounting partitions ===");

    if let Err(e) = mount_partition("system", &system_lowerdir) {
        warn!("system mount failed: {:#}", e);
    }

    for (k, v) in partition_lowerdir {
        if let Err(e) = mount_partition(&k, &v) {
            warn!("{} mount failed: {:#}", k, e);
        }
    }

    info!("=== mount_modules_systemlessly END (success) ===");
    Ok(())
}
