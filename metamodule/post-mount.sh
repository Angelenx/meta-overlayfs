#!/system/bin/sh
#
# post-mount 阶段的清理逻辑。
# `nuke-ext4-sysfs` 用于在 ext4 镜像挂载后尽量清理/重建相关 sysfs 节点，
# 避免一些设备上出现旧节点导致的异常行为（例如无法正常识别 mounted image）。
#
ksud kernel nuke-ext4-sysfs /data/adb/modules/meta-overlayfs/mnt
