# DDToRun

面向 VPS 一键重装（dd）场景的 Alpine Linux 镜像构建仓库。镜像只做一件事：开机后把业务二进制拉下来跑起来。

## 两个口味

| 产物 | 说明 |
| --- | --- |
| `vpsvga` | VGA kiosk。tty1 用 fbterm + 文泉驿字体把业务全屏渲染成中文界面，不装 sshd。**没有纯文本回退**：拿不到 `/dev/fb0` 就报错退出并由 inittab 重新拉起。 |
| `vpsssh` | 无头模式。sshd 监听 22（仅密钥登录），业务作为受管后台服务运行。 |

两者共用同一套内核、网络、时钟、根分区自动扩容逻辑，只在「怎么跑业务」上有差别。

## 仓库结构

```
build/
├── build.sh              # 主机侧入口：取工具 → 建盘 → 调官方工具 → 装 MBR → 调优 → 导出
├── lib/
│   ├── common.sh         # 日志、依赖检查、下载封装
│   ├── disk.sh           # raw 镜像、loop 设备、MBR 分区表
│   ├── provision.sh      # alpine-make-vm-image / apk.static / fbterm 源码
│   └── finalize.sh       # syslinux MBR、ext4 调优、产物导出
├── setup.sh              # chroot 入口：按文件名顺序 source 各阶段
├── rootfs/               # chroot 内阶段，一个文件一类职责
│   ├── 00-system.sh      # 主机名、sysctl、服务裁剪、inittab
│   ├── 10-network.sh     # DHCP 网卡、固定 DNS
│   ├── 20-storage.sh     # 根分区自动扩容
│   ├── 30-time.sh        # 开机 NTP 校时
│   ├── 40-ssh.sh         # sshd（仅无头模式）
│   ├── 50-kiosk.sh       # 编译 fbterm、安装 tty1 启动器（仅 VGA）
│   ├── 60-app.sh         # 安装 app-runner 及其服务
│   └── 70-kernel.sh      # 模块种子、BBR、模块树裁剪、initramfs 重建
├── files/                # 进镜像的静态文件
│   ├── app-runner.openrc # 业务服务定义
│   ├── app-runner.conf   # respawn 参数
│   ├── app-runner-fb.sh  # tty1 kiosk 启动器
│   ├── grow-root.openrc  # 扩容服务
│   ├── time-sync.openrc  # 校时服务
│   └── initramfs-init    # 精简 initramfs 的 init
└── vendor/
    ├── app-runner.go     # 业务下载/启动器源码
    ├── ssh_host_ed25519_key(.pub)
    └── ssh_user_key.pub
.github/
├── workflows/build.yml   # 只构建与发布
├── workflows/pve-test.yml # 手动触发：在 PVE 上开机抓屏
└── pve/pve-e2e.py        # PVE 真机启动测试
scripts/check.sh          # 本地语法/格式检查
```

`alpine-make-vm-image --script-chroot` 会把整个 `build/` 目录 bind 到 chroot 的 `/mnt`，所以 `setup.sh` 和 `rootfs/*.sh` 在镜像内按 `/mnt/...` 路径互相引用。

## 构建

```sh
# 本地（需要 root：losetup / mount / mkfs）
HEADLESS_SSH=false bash build/build.sh   # vpsvga
HEADLESS_SSH=true  bash build/build.sh   # vpsssh
```

产物在 `dist/`。CI 走 `.github/workflows/build.yml` 手动触发，两个口味并行构建后一起发布到同一个 release tag（默认 `dd`）。

release 里除 zstd 压缩的 raw 外还带一份 `<flavor>.qcow2`：PVE 的 `import-from` 只认 raw/qcow2/vmdk，qcow2 让节点直接拉取并分配磁盘，既不用在节点上解压，也不必让镜像字节走一遍租户隧道。

可调环境变量：`APP_URL`、`IMAGE_SIZE_GB`、`ALPINE_BRANCH`、`ALPINE_MIRROR`、`KERNEL_FLAVOR`、`HEADLESS_SSH`、`PACKAGES`（追加）、`CGO_COMPAT`、`KEEP_WORK`。

## 测试

**测试只在 PVE 上做，Actions 不跑虚拟机。** 整条链路只走租户 API，不碰宿主机 shell：

```sh
.github/pve/pve-e2e.py --asset vpsvga --vga qxl --disk-bus scsi
```

凭据全从环境变量来（`PVE_HOST`、`PVE_API_PORT`、`PVE_USER`、`PVE_API_PASS`、`PVE_TLS_FP`，可选 `PVE_STORAGE` / `PVE_POOL` / `PVE_FETCH_IP`，缺省时从 API 自动发现）。

镜像不走租户隧道，那是计费的 NAT 通路。脚本先确认 `import` 存储里有 `<asset>.qcow2`，没有就临时起一个 LXC 抓取容器：节点用自己的出口从 GitHub 拉这个 qcow2（release 里带一份，`import-from` 只认 raw/qcow2/vmdk，不必在节点上解压），再经节点本地 API 落进存储。容器不打印任何东西——开机时控制台没有读者，写阻塞会卡死 init——进度写成阶梯文件（第 N 步 8N MiB，失败 +4 MiB），靠存储卷的 `used` 反读，失败即销毁。镜像到位后用 `import-from` 建机，抓帧走 `vncproxy` + 网关 WebSocket（ticket 同时是 VNC 密码），桥到本地端口交给 vncdotool。

租户角色里没有 `VM.Config.Options`，因此建机不带 `name` / `bios` / `onboot` / `agent`：这些选项会被直接拒绝，其余（`cores`、`memory`、`cpu=host`、`vga`、`machine`、`scsi0`、`net0`、`boot`）都可用。没有 `agent=1` 也意味着 rc-status / 日志去重 / 密钥登录这些机内断言无从谈起——**抓到的帧就是断言**：`vpsvga` 该出现 fbterm 中文界面，`vpsssh` 该停在无登录的启动信息。虚机 CPU 固定 `host`：app-runner 按 `GOAMD64=v3` 编译，默认 `kvm64` 基线缺 v3 指令集会拒绝运行。

也可以手动触发 **PVE Real-Machine Boot Test**，选 `asset` / `vga` / `disk_bus` / `memory_mb` 组合，抓到的帧作为 artifact 上传。

## 两个刻意的设计

**initramfs 只装 busybox。** 官方 init 走 `nlplug-findfs`（依赖 libcryptsetup），base 特色还带 `apk`，两者会把整套 OpenSSL/device-mapper 拖进来；换成 busybox 后，独立 `kmod` 又因为支持压缩模块直接依赖 libcrypto。最终做法是自定义 `tiny` 特色 + 只用 busybox 的 `modprobe`/`mdev`，initramfs 从 5.43 MB 降到 3.01 MB。

**app-runner 不用 net/http。** `net/http` 会连带 HTTP/2 和整套 transport 抽象。改成 `crypto/tls` 上手写最小 HTTP/1.1：单流 GET、最多 10 次重定向、chunked 与 Content-Length、读超时 30s 的 stall 看门狗、固定 6 次重试、最小环境变量 `exec`。

**体积由 Go 版本决定，不是编译开关。** 同一份源码用 go1.27.1、`GOAMD64=v3`、`-s -w` 实测：不加任何 `GOEXPERIMENT` 是 4,845,728 字节，只加 `newinliner` 是 4,858,016，当前完整组合是 4,849,824 —— `simd` / `greenteagc` / `sizespecializedmalloc` 对体积没有影响，`newinliner` 反而 +12 KB（换内联质量，保留）。同一源码用 go1.23 编是 4,149,400 字节，那 700 KB 的差距来自 1.24 之后的运行时，调 flags 拿不回来。`-buildid=` 只省 36 字节。

## 约束

- 业务 URL 编译进二进制，不落配置文件。
- 下载不分块、不多线程，失败删临时文件从头再来。
- 业务进程不继承环境变量，只给固定 `PATH`。
- 每个 flavor 的镜像总量（`vpsvga` / `vpsssh`）均以 MB 汇报。
