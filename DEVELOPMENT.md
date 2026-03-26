# meta-overlayfs 开发文档

本文档用于帮助开发者理解 `meta-overlayfs` 这个 KernelSU 元模块（metamodule）的运行时结构，并给出可扩展/可调试的开发思路。

## 1. 这个仓库做了什么

`meta-overlayfs` 提供“系统无修改”的挂载能力：在启动过程中，把普通模块的 `system/ vendor/ product/ ...` 内容通过 `overlayfs` 挂载到目标分区目录上。

为了降低探测/耦合风险、同时支持读写层，它采用了“双目录架构”：

- 元数据（metadata）：`/data/adb/modules/`，普通模块安装后的 `module.prop`、`disable`、`skip_mount` 等标记都在这里。
- 内容（content）：`/data/adb/metamodule/mnt/`，由 metamodule 把普通模块的分区目录（来自 `system/vendor/...`）拷贝/归档到一个 ext4 镜像中，供启动时作为 overlayfs 的 `lowerdir` 使用。

## 2. 目录结构总览

仓库根目录包含两类内容：

- `src/`：Rust 二进制实现，负责“真正的 overlayfs 挂载逻辑”（元模块挂载处理程序的核心）。
- `metamodule/`：元模块打包内容（`module.prop`、各生命周期脚本、以及安装时选择的二进制文件占位）。

关键文件：

- `src/main.rs`：程序入口；默认执行挂载；当参数为 `xcp` 时执行稀疏文件复制逻辑（用于镜像复用）。
- `src/mount.rs`：挂载实现（扫描 enabled 模块 -> 收集 lowerdir -> 挂载 system/vendor/... 的 overlayfs）。
- `src/xcp.rs`：`xcp` 子命令实现；复制稀疏文件，并可选择“挖洞”（hole punching）。
- `metamodule/metamount.sh`：元模块在启动阶段的入口；挂载/初始化 ext4 镜像，然后执行 Rust 二进制。
- `metamodule/metainstall.sh`：普通模块安装钩子；把普通模块的分区目录拷贝到 ext4 镜像中。
- `metamodule/metauninstall.sh`：普通模块卸载钩子；从 ext4 镜像中移除模块内容。
- `metamodule/customize.sh`：安装元模块时的自定义脚本；选择架构二进制并创建/复用 `modules.img` ext4 镜像文件。
- `metamodule/post-mount.sh` / `metamodule/uninstall.sh`：挂载后的清理/卸载清理。

## 3. 运行时与生命周期（对应 KernelSU metamodule 语义）

这里的元模块相关脚本主要涉及两个时间点：

1. 普通模块安装/卸载时
   - 安装：KernelSU Manager/ksud 安装模块时，会在“提取文件后、安装完成前”调用 `metainstall.sh`（脚本以 source 方式内置到安装程序）。
   - 卸载：普通模块卸载期间，KernelSU 会在删除模块目录之前调用 `metauninstall.sh`。

2. 启动阶段挂载时
   - `metamount.sh` 在启动的 `post-fs-data` 相关阶段被执行（具体顺序遵循 KernelSU/KernelSU Manager 的约定）。
   - `metamount.sh` 会确保 ext4 镜像已挂载，设置环境变量，然后阻塞式执行 Rust 挂载程序。

> 重要：本项目的 Rust 二进制会在 `metamount.sh` 执行时被调用，因此“是否安装了元模块”直接决定依赖挂载的普通模块是否生效。

## 4. 数据模型：metadata 与 content

### 4.1 metadata（模块启用与过滤）

Rust 在 `collect_enabled_modules(metadata_dir)` 中扫描 metadata 目录下的子目录：

- 若存在 `disable`：跳过该模块。
- 若存在 `skip_mount`：跳过该模块（即使模块本身安装成功）。
- 若目录缺少 `module.prop`（且不是 `.rw` 目录）：也会跳过。

metadata 的默认路径由 metamodule 脚本导出：

- `MODULE_METADATA_DIR=/data/adb/modules`

### 4.2 content（overlayfs lowerdir 的来源）

metamount 设置：

- `MODULE_CONTENT_DIR=$MNT_DIR`，默认 `MNT_DIR=/data/adb/metamodule/mnt`

其中 `$MODULE_CONTENT_DIR/$module_id/` 下应包含以下分区目录（按模块 payload 实际情况存在）：

- `system/`
- `vendor/`
- `product/`
- `system_ext/`
- `odm/`
- `oem/`

这些目录在普通模块安装期间由 `metainstall.sh` 拷贝进 ext4 镜像：`/data/adb/metamodule/modules.img`（通过 loop 挂载成 ext4 后得到 `mnt/`）。

## 5. 挂载实现要点（Rust：`src/mount.rs`）

### 5.1 overlayfs source 识别：必须设置为 `KSU`

在 `mount_overlayfs()` 中，会调用：

- `fsconfig_set_string(fs, "source", "KSU")`

这对应 KernelSU 对挂载归属的识别需求：如果不设置，可能导致卸载/协调失败，甚至出现“无法被 KernelSU 正确管理”的行为。

### 5.2 lowerdir 组合方式

`mount_overlayfs(lower_dirs, lowest, ...)` 逻辑为：

- `lowerdir` 由两部分组成：
  - `lower_dirs`：来自 enabled 普通模块的对应分区目录（例如多个模块的 `.../system`）。
  - `lowest`：来自“stock 根目录”（也就是当前分区的原始挂载内容）。

### 5.3 child mounts 协调

`mount_overlay()` 会先在根目录挂载一次 overlay，然后遍历该分区下已有的子挂载点（通过 `/proc/self/mountinfo` 获取）。

对于每个子挂载点：

- 如果模块没有覆盖对应相对路径，则退化为 `bind_mount(stock_root, mount_point)`。
- 如果模块覆盖则继续尝试 overlayfs。

这样可以尽量降低对系统既有挂载结构的破坏。

## 6. 安装元模块时的镜像创建（Shell：`metamodule/customize.sh`）

`customize.sh` 做两件事：

1. 选择架构二进制
   - 通过 `ro.product.cpu.abi` 判断 ABI，并把对应的 `meta-overlayfs-*` 重命名为 `meta-overlayfs`。
2. 创建或复用 `modules.img` ext4 稀疏文件
   - 若之前已经存在镜像，则使用 Rust 的 `xcp` 命令复制稀疏内容到新位置。
   - 若不存在，则 `truncate` 创建 sparse file，并用 `mke2fs` 格式化（禁用 journal）。

## 7. 普通模块安装/卸载钩子行为（Shell：`metainstall.sh` / `metauninstall.sh`）

### 7.1 安装：`metainstall.sh`

核心流程：

- `install_module`：调用内置安装逻辑完成解包/安装元数据。
- `module_requires_overlay_move`：
  - 若存在 `skip_mount`，则不把 payload 移入镜像。
  - 若不存在 `system/` 目录，也不把 payload 移入镜像（因为该模块很可能不需要分区挂载）。
- `ensure_image_mounted` + `post_install_to_image`：
  - 确保 ext4 镜像已挂载到 `$MNT_DIR`
  - 将 `system/ vendor/ product/ ...` 目录拷贝到 `$MNT_DIR/$MODID/`。

> 注意：该实现使用 `cp -af` 拷贝 payload 到镜像中，因此原目录可能仍留在 `/data/adb/modules/<module_id>/`。这主要影响磁盘占用，不影响功能正确性。

### 7.2 卸载：`metauninstall.sh`

卸载时从 `$MNT_DIR/$MODULE_ID/` 移除该模块归档的分区目录。

> 该脚本不会负责卸载 ext4 镜像本体，镜像清理在 metamodule 退载阶段由 `uninstall.sh` 做。

## 8. 构建与打包

本仓库使用 `build.sh`：

- 同时构建 `aarch64-linux-android` 与 `x86_64-linux-android` 目标
- 把 `meta-overlayfs` 二进制和 `metamodule/*.sh` 打包成 zip

常见用法：

```bash
./build.sh
```

输出 zip 在 `target/` 目录。

## 9. 调试建议

建议按“挂载程序是否工作 -> overlay 是否正确 -> 镜像内容是否存在”三步排查：

1. 开启日志
   - 启动时设置 `RUST_LOG=info`（或 debug）后观察日志。
2. 检查 metadata 与 content
   - metadata 中模块是否有 `disable/skip_mount` 标记。
   - content 中是否存在 `$MODULE_CONTENT_DIR/<module_id>/system` 等目录。
3. 检查挂载与 source 标记
   - `mount`/`findmnt` 中确认 overlayfs 是否挂上了对应的分区路径。
   - Rust 实现中已设置 `"source"="KSU"`；如果你改动了 `mount_overlayfs`，务必保持该行为。

## 10. 如何扩展/改造

最常见的扩展方向：

1. 支持更多 partition
   - 同步改动 `metamount.sh` 的 `PARTITIONS` 列表
   - 同步改动 `mount_modules_systemlessly()` 中的 partition 列表收集逻辑
2. 调整读写层策略
   - 当前读写层读取自 `/data/adb/modules/.rw/<partition>/{upperdir,workdir}`
   - 若你更换路径或结构，需要同时更新 Shell 与 Rust。
3. 替换挂载实现
   - 你可以保留 ext4 镜像归档方式，仅替换 Rust 的 overlay/bind 挂载策略。
   - 或者保留挂载实现，替换 `metainstall.sh` / `metauninstall.sh` 的归档机制。

