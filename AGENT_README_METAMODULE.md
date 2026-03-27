# AGENT_README 核心经验速查（meta-overlayfs / KernelSU 元模块）

本文是对 `AGENT_README.md` 的浓缩版总结，目标是后续快速回看时，能在最短时间内抓住“怎么做、为什么、容易错在哪”。

## 1) 元模块到底是什么（定位）

- 元模块（metamodule）是 KernelSU 的“模块基础设施插件”：
  - 它不是普通功能模块，而是负责“模块如何安装、如何挂载、如何卸载清理”的底层机制。
- KernelSU 只保留稳定核心，把可变的挂载/安装实现下放给元模块：
  - 降低 KernelSU 自身被检测面；
  - 提升演进速度和策略多样性（overlayfs、magic mount、无挂载、自定义实现等）。
- **单实例约束**：同一时间只能有一个元模块激活，避免挂载冲突。

## 2) 对用户和普通模块作者的实际影响

- 用户层面：
  - 没有安装元模块时，依赖挂载的模块不会生效（脚本类无挂载模块可不依赖）。
  - 卸载元模块后，设备仍能启动，但模块改动不会被挂载应用。
- 常规模块开发者：
  - 通常不需要改代码；
  - 只要用户安装了兼容元模块（如 `meta-overlayfs`），模块可按既有方式工作。

## 3) 元模块识别与文件结构（必记）

- `module.prop` 必须声明：
  - `metamodule=1`（或 `metamodule=true`）
- 元模块可提供三个专用钩子：
  - `metamount.sh`：挂载处理（启动阶段）
  - `metainstall.sh`：常规模块安装钩子（source 方式执行）
  - `metauninstall.sh`：常规模块卸载前清理钩子
- 同时可使用标准生命周期脚本：
  - `post-fs-data.sh` / `service.sh` / `boot-completed.sh` / `uninstall.sh` 等。

## 4) 最关键技术红线：挂载源必须标记为 KSU

- 进行挂载时，**source/dev 必须设置为 `"KSU"`**：
  - 例如现代 API：`fsconfig_set_string(fs, "source", "KSU")`
  - 这是 KernelSU 识别、后续卸载和管理挂载的前提。
- 这条要求是实现正确性的核心，不满足会导致识别/卸载链路异常。

## 5) 执行顺序（决定行为时机）

- `post-fs-data` 阶段的关键顺序：
  1. 通用 `post-fs-data.d`
  2. `restorecon` / `sepolicy.rule`
  3. 元模块 `post-fs-data.sh`
  4. 常规模块 `post-fs-data.sh`
  5. 加载 `system.prop`
  6. 元模块 `metamount.sh`（此处完成模块挂载）
  7. `post-mount.d`（通用 -> 元模块 -> 常规模块）
- `service`、`boot-completed` 阶段均是：
  - 通用 `.d` -> 元模块脚本 -> 常规模块脚本。
- 结论：
  - 元模块生命周期脚本始终先于常规模块；
  - `metamount.sh` 在所有 post-fs-data 脚本之后运行。

## 6) 符号链接机制（稳定入口）

- 激活元模块后会建立：
  - `/data/adb/metamodule -> /data/adb/modules/<metamodule_id>`
- 价值：
  - 无论实际 ID，均可通过稳定路径访问当前活动元模块；
  - 便于检测、配置与脚本编写。

## 7) 官方参考实现 meta-overlayfs 的经验抽象

- 采用“双目录架构”：
  - 元数据目录：`/data/adb/modules/`（标记、属性、快速扫描）
  - 内容目录：`/data/adb/metamodule/mnt/`（实际模块内容，位于 ext4 镜像）
- `metamount.sh` 负责：
  - 确保 ext4 镜像挂载就绪；
  - 导出 metadata/content 目录环境变量；
  - 调用核心挂载二进制执行实际挂载逻辑。
- overlayfs 特性：
  - 支持多个分区（system/vendor/product/system_ext/odm/oem）；
  - 支持读写层目录（`.rw`）。

## 8) 开发最佳实践（高价值清单）

- 始终设置 `source=KSU`（第一优先级）。
- 尊重标准控制标记：
  - `disable`、`skip_mount` 必须正确处理。
- 错误处理要“保守且可恢复”：
  - 启动流程阻塞点在 `metamount.sh`，异常容易引发启动问题。
- 保留必要日志（`echo` 或其他方式）便于故障定位。
- 兼容迁移：
  - 对从其他方案迁移的用户提供清晰路径和行为说明。

## 9) 测试与发布门槛（避免启动事故）

- 发布前至少验证：
  - 干净环境安装；
  - 多类型模块挂载正确性；
  - 与常见模块兼容性；
  - 卸载和清理完整性；
  - 启动性能（`metamount.sh` 为阻塞脚本）；
  - 异常路径不会引发启动循环。

## 10) 常见误区与结论

- “必须装 meta-overlayfs 吗？”
  - 不是必须；它是官方参考和高兼容默认实现。
- “能同时装多个元模块吗？”
  - 不能，只能一个。
- “卸载唯一元模块后会怎样？”
  - 系统能起，但模块挂载修改失效，直到安装新的元模块。

---

## 一页式行动指南（后续快速执行）

- 要做元模块：先确保 `metamodule=1` 和三大钩子设计清晰。
- 要做挂载：第一时间落实 `source=KSU`，再谈其余优化。
- 要保稳定：`metamount.sh` 逻辑简洁、可观测、可失败回退。
- 要保兼容：严格处理 `disable/skip_mount`，按标准执行顺序思考问题。
- 要发布：把“安装-挂载-卸载-重启-异常恢复”完整跑通后再交付。
