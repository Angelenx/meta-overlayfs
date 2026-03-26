use anyhow::Result;
use log::info;

mod defs;
mod mount;
mod xcp;

fn main() -> Result<()> {
    // metamount.sh 会直接运行本二进制进行挂载。
    // customize.sh 中用于“复用已有 ext4 镜像”的场景，则会调用本二进制的子命令 `xcp`。
    let args: Vec<String> = std::env::args().collect();
    if matches!(args.get(1), Some(cmd) if cmd == "xcp") {
        return xcp::run(&args[2..]);
    }

    // Initialize logger.
    // RUST_LOG 由外部控制（例如通过启动脚本或手动设置）。
    env_logger::builder()
        .filter_level(log::LevelFilter::Info)
        .init();

    info!("meta-overlayfs v{}", env!("CARGO_PKG_VERSION"));

    // Dual-directory support: metadata + content.
    // 两个目录通常由 metamodule/metamount.sh 导出环境变量。
    let metadata_dir = std::env::var("MODULE_METADATA_DIR")
        .unwrap_or_else(|_| defs::MODULE_METADATA_DIR.to_string());
    let content_dir = std::env::var("MODULE_CONTENT_DIR")
        .unwrap_or_else(|_| defs::MODULE_CONTENT_DIR.to_string());

    info!("Metadata directory: {}", metadata_dir);
    info!("Content directory: {}", content_dir);

    // Execute dual-directory mounting
    mount::mount_modules_systemlessly(&metadata_dir, &content_dir)?;

    info!("Mount completed successfully");
    Ok(())
}
