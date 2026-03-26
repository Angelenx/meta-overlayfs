# meta-overlayfs

A reference implementation of the overlayfs mount handler for KernelSU metamodules. This is not intended to be a state-of-the-art implementation, but rather a starting point for developers to understand and build upon.

## Installation

```bash
adb push meta-overlayfs-vX.Y.Z.zip /sdcard/
adb shell su -c 'ksud module install /sdcard/meta-overlayfs-vX.Y.Z.zip'
adb reboot
```

Or install via KernelSU Manager → Modules.

**Note**: The metamodule is installed as a regular module to `/data/adb/modules/meta-overlayfs/`, with a symlink created at `/data/adb/metamodule` pointing to it.

## How It Works

Uses dual-directory architecture for ext4 image support:

- **Metadata**: `/data/adb/modules/` - Contains `module.prop`, `disable`, `skip_mount` markers
- **Content**: `/data/adb/metamodule/mnt/` - Contains `system/`, `vendor/` etc. directories from ext4 images

Scans metadata directory for enabled modules, then mounts their content directories as overlayfs layers.

### Supported Partitions

system, vendor, product, system_ext, odm, oem

### Read-Write Layer

Optional upperdir/workdir support via `/data/adb/modules/.rw/`:

```bash
mkdir -p /data/adb/modules/.rw/system/{upperdir,workdir}
```

## Environment Variables

- `MODULE_METADATA_DIR` - Metadata location (default: `/data/adb/modules/`)
- `MODULE_CONTENT_DIR` - Content location (default: `/data/adb/metamodule/mnt/`)
- `RUST_LOG` - Log level (debug, info, warn, error)

## Architecture

Automatically selects aarch64 or x86_64 binary during installation (~500KB).

## Building

```bash
./build.sh
```

Output: `target/meta-overlayfs-vX.Y.Z.zip`

## Development
See [`DEVELOPMENT.md`](./DEVELOPMENT.md) for a deeper explanation of the runtime flow, the Rust mount implementation, and how to extend/test this metamodule.

## License

GPL-3.0
