use anyhow::{bail, Context, Result};
use hole_punch::*;
use std::{
    fs::{File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::Path,
};

/// 处理 `meta-overlayfs xcp ...` 子命令。
///
/// 用途（本仓库内）：
/// 在 `metamodule/customize.sh` 安装元模块时，如果发现旧的 `modules.img` ext4 镜像，
/// 会用本子命令复制稀疏文件内容到新镜像位置，避免无谓的完整写入。
pub fn run(args: &[String]) -> Result<()> {
    let mut positional: Vec<&str> = Vec::with_capacity(2);
    let mut punch_hole = false;

    for arg in args {
        match arg.as_str() {
            "--punch-hole" => punch_hole = true,
            "-h" | "--help" => {
                print_usage();
                return Ok(());
            }
            _ => positional.push(arg),
        }
    }

    if positional.len() < 2 {
        print_usage();
        bail!("xcp requires source and destination paths");
    }
    if positional.len() > 2 {
        bail!("unexpected argument: {}", positional[2]);
    }

    copy_sparse_file(positional[0], positional[1], punch_hole)
}

fn print_usage() {
    eprintln!("Usage: meta-overlayfs xcp <src> <dst> [--punch-hole]");
}

// TODO: use libxcp to improve the speed if cross's MSRV is 1.70
pub fn copy_sparse_file<P: AsRef<Path>, Q: AsRef<Path>>(
    src: P,
    dst: Q,
    punch_hole: bool,
) -> Result<()> {
    // 1) 打开源文件/目标文件
    // 2) 通过 `scan_chunks()` 找到源文件的稀疏段
    // 3) 仅拷贝 Data 段；如果开启 `punch_hole`，且 data 段全为 0，则跳过该段写入
    let mut src_file = File::open(src.as_ref())
        .with_context(|| format!("failed to open {}", src.as_ref().display()))?;
    let mut dst_file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(dst.as_ref())
        .with_context(|| format!("failed to open {}", dst.as_ref().display()))?;

    dst_file.set_len(src_file.metadata()?.len())?;

    let segments = src_file.scan_chunks()?;
    for segment in segments {
        if let SegmentType::Data = segment.segment_type {
            let start = segment.start;
            let end = segment.end + 1;

            src_file.seek(SeekFrom::Start(start))?;
            dst_file.seek(SeekFrom::Start(start))?;

            let mut buffer = [0; 4096];
            let mut total_bytes_copied = 0;

            while total_bytes_copied < end - start {
                let bytes_to_read =
                    std::cmp::min(buffer.len() as u64, end - start - total_bytes_copied);
                let bytes_read = src_file.read(&mut buffer[..bytes_to_read as usize])?;

                if bytes_read == 0 {
                    break;
                }

                if punch_hole && buffer[..bytes_read].iter().all(|&x| x == 0) {
                    dst_file.seek(SeekFrom::Current(bytes_read as i64))?;
                    total_bytes_copied += bytes_read as u64;
                    continue;
                }
                dst_file.write_all(&buffer[..bytes_read])?;
                total_bytes_copied += bytes_read as u64;
            }
        }
    }

    Ok(())
}
