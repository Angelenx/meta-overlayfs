use anyhow::Result;
use log::info;
use std::fs::OpenOptions;
use std::io::Write;

mod defs;
mod mount;
mod xcp;

/// 初始化自定义 logger，所有日志同时输出到 stderr 和 /dev/kmsg
fn init_logger_with_dmesg() {
    env_logger::Builder::from_default_env()
        .format(|buf, record| {
            let msg = format!("[meta-overlayfs] {}", record.args());
            // 同时写到 dmesg
            if let Ok(mut file) = OpenOptions::new().append(true).open("/dev/kmsg") {
                let _ = writeln!(file, "{}", msg);
            }
            writeln!(buf, "{}", msg)
        })
        .filter_level(log::LevelFilter::Info)
        .try_init()
        .ok();
}

fn main() -> Result<()> {
    // metamount.sh 会直接运行本二进制进行挂载。
    // customize.sh 中用于"复用已有 ext4 镜像"的场景，则会调用本二进制的子命令 `xcp`。
    let args: Vec<String> = std::env::args().collect();
    if matches!(args.get(1), Some(cmd) if cmd == "xcp") {
        return xcp::run(&args[2..]);
    }

    // Initialize logger with dmesg output.
    init_logger_with_dmesg();

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
    match mount::mount_modules_systemlessly(&metadata_dir, &content_dir) {
        Ok(()) => {
            info!("Mount completed successfully");
            Ok(())
        }
        Err(e) => {
            info!("Mount failed: {:#}", e);
            Err(e)
        }
    }
}
