# DDToRun

面向 VPS 一键重装（dd）场景的 Alpine Linux 镜像构建仓库。镜像只做一件事：开机后把业务二进制拉下来跑起来。

## 两个口味

| 产物 | 说明 |
| --- | --- |
| `vpsvga` | VGA kiosk。tty1 用 fbterm + 文泉驿字体把业务全屏渲染成中文界面，不装 sshd。**没有纯文本回退**：拿不到 `/dev/fb0` 就报错退出并由 inittab 重新拉起。 |
| `vpsssh` | 无头模式。sshd 监听 22（仅密钥登录），业务作为受管后台服务运行。 |
| `vpsssh-dbg` | `vpsssh` 的调试孪生体，**只给测试用**：内核挂 `console=ttyS0`、开 ttyS0 getty、root 用固定口令，并在开机末尾把自检结果打到串口。它发布在 `<tag>-dbg` 而不是生产 tag 上，生产环境不要用它。 |

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

生产产物（`vpsvga` / `vpsssh`）发布到 `release_tag`，调试产物（`vpsssh-dbg`）单独发布到 `<release_tag>-dbg`：它带着串口 getty 和固定 root 口令，不该和生产镜像躺在一个 release 里。

release 里除 zstd 压缩的 raw 外还带一份 `<flavor>.qcow2`：PVE 的 `import-from` 只认 raw/qcow2/vmdk，qcow2 让节点直接拉取并分配磁盘，既不用在节点上解压，也不必让镜像字节走一遍租户隧道。

可调环境变量：`APP_URL`、`IMAGE_SIZE_GB`、`ALPINE_BRANCH`、`ALPINE_MIRROR`、`KERNEL_FLAVOR`、`HEADLESS_SSH`、`PACKAGES`（追加）、`CGO_COMPAT`、`DEBUG_SERIAL`（串口调试构建）、`KEEP_WORK`。

`DEBUG_SERIAL=true` 会带上 alpine-make-vm-image 的 `--serial-console`（内核命令行加 `console=ttyS0`、放开 inittab 的 ttyS0 getty、写 securetty），安装 `boot-selftest` 服务，并把 root 口令从随机哈希换成固定值——串口能登录是这套调试构建的前提。

## 测试

**测试只在 PVE 上做，Actions 不跑虚拟机。** 整条链路只走租户 API，不碰宿主机 shell：

```sh
.github/pve/pve-e2e.py --asset vpsvga --vga qxl --disk-bus scsi
```

凭据全从环境变量来（`PVE_HOST`、`PVE_API_PORT`、`PVE_USER`、`PVE_API_PASS`、`PVE_TLS_FP`，可选 `PVE_STORAGE` / `PVE_POOL` / `PVE_FETCH_IP`，缺省时从 API 自动发现）。

镜像不走租户隧道，那是计费的 NAT 通路。脚本先确认 `import` 存储里有 `<asset>.qcow2`，没有就临时起一个 LXC 抓取容器：节点用自己的出口从 GitHub 拉这个 qcow2（release 里带一份，`import-from` 只认 raw/qcow2/vmdk，不必在节点上解压），再经节点本地 API 落进存储。容器不打印任何东西——开机时控制台没有读者，写阻塞会卡死 init——进度写成阶梯文件（第 N 步 8N MiB，失败 +4 MiB），靠存储卷的 `used` 反读，失败即销毁。镜像到位后用 `import-from` 建机，抓帧走 `vncproxy` + 网关 WebSocket（ticket 同时是 VNC 密码），桥到本地端口交给 vncdotool。

租户角色里没有 `VM.Config.Options`，因此建机不带 `name` / `bios` / `onboot` / `agent`：这些选项会被直接拒绝，其余（`cores`、`memory`、`cpu=host`、`vga`、`machine`、`scsi0`、`net0`、`boot`）都可用。没有 `agent=1` 也意味着 rc-status / 日志去重 / 密钥登录这些机内断言无从谈起。生产镜像里没有串口控制台，所以**抓到的帧就是断言**：`vpsvga` 该出现 fbterm 中文界面，`vpsssh` 该停在无登录的启动信息。

要拿到真正的机内断言，用调试口味 `vpsssh-dbg` 加 `--serial`：脚本在开机后立刻连上 `termproxy`（经 `vncwebsocket` 拿到 guest 的 ttyS0，串口是 unix socket，没人在线时输出会被丢弃，所以必须先连），把整段启动日志存下来，再从里面取 `boot-selftest` 打的 `SELFTEST key=value` 行做断言：

```sh
.github/pve/pve-e2e.py --tag dd-dbg --asset vpsssh-dbg --vga std --disk-bus scsi --serial
```

断言项是 `sshd=started`、`app-runner=started`、`app-runner-starts=1`（受管服务只能启动一次，重启风暴会让这条挂掉）、`rootpw=set`、根分区已扩容（1G 盘 `df` 约 990 MiB，门槛设 900），最后一行 `SELFTEST-RESULT pass|fail`。串口日志落在 `.github/pve/out/serial-<asset>.log`。虚机 CPU 固定 `host`：app-runner 按 `GOAMD64=v3` 编译，默认 `kvm64` 基线缺 v3 指令集会拒绝运行。

加 `--net-check` 会断言自检里的网络实测（见下），加 `--ssh-check` 会断言镜像内做的 SSH 密钥登录回环测试。

也可以手动触发 **PVE Real-Machine Boot Test**，选 `asset` / `vga` / `disk_bus` / `memory_mb` 组合，抓到的帧作为 artifact 上传。

## 兼容性矩阵

镜像只做一件事：把业务二进制拉下来执行。`app-runner` 用的是 `syscall.Exec`，所以「能不能跑」由内核判定，失败也只有一条 `exec failed: ...`。调试镜像的串口自检会在开机后等到这一步并上报结论（`app-exec=ok|no-loader|arch|failed|timeout`），e2e 用 `--expect-app` 断言。

已验证的组合（真机、串口断言）：

| 业务二进制 | 镜像 | 结论 |
| --- | --- | --- |
| 静态 Go（hysteria 18.7 MB） | 默认 | `ok`，真的跑起来 |
| 静态 Go + `CGO_COMPAT=true` | 默认 | `ok`，glibc 兼容层不影响静态程序 |
| `.tar.gz` 包（sing-box） | 默认 | `arch` —— `exec format error`，贴错链接的典型错 |
| AArch64 二进制 | 默认 | `arch` |
| glibc 动态 ELF（`compat-fixtures/glibc-hello`） | 默认 | `no-loader` —— 缺 `/lib64/ld-linux-x86-64.so.2` |
| glibc 动态 ELF | `CGO_COMPAT=true` | `ok` —— 程序自己打出 `alive pid=…`，gcompat 兼容层确实让它跑起来了 |

`compat-fixtures` 那个 release 里放的就是这条轴用的小 ELF（16 KB，自己编的，不是业务代码），客户机可以匿名下载。

两点说明：

- `app-exec=ok` 是权威结论（内核真的把它加载起来了）；`app=alive|exited` 现在扫 `/proc/*/cmdline` 的 `argv[0]`（不再用 `pidof` 猜进程名，gcompat 加载器改名也不会误报）。短命夹具跑完就退，`exited` 属实，不影响 `ok`。
- 下载是「每次开机拉一次最新」：业务程序正常退出后受管服务重启会再拉一次（这是要的）；但 `exec` 失败后的内部重试循环复用已下的副本，不会每 2 秒重下整个文件。串口日志里的 `reusing the copy fetched in this boot` 就是这条护栏。

## 网络性能与 SSH / VGA 真机验证

调试自检除了启动契约，还在机内实测三件事，走 guest 自己的 NAT 出口、用国内镜像（阿里云），反映真实 VPS 体验而不是跨洋链路：

- `net-gw-rtt-ms`：ping 默认网关 4 次的平均 RTT；
- `net-dns-ms`：解析 `mirrors.aliyun.com` 的耗时；
- `net-down-mbps` / `net-probe-bytes`：反复下载阿里云 Alpine minirootfs 累计满 2 秒，按字节/秒算吞吐（busybox `date` 没有可靠亚秒字段，所以用整秒累计而不是给单个小文件计时）。

SSH 不靠「端口开着」就算过：调试镜像内置一段回环自检——生成一次性 ed25519 密钥、写进 `authorized_keys`、用 `ssh root@127.0.0.1` 真正做一次密钥认证，上报 `ssh-login=ok|fail`，同时上报 `ssh-keyonly`（`sshd -T` 的 `passwordauthentication`）和 `ssh-listen22`。e2e `--ssh-check` 断言这三条。

真机结论（PVE 租户 API，`netssh6` / `netssh6-dbg` release，业务夹具 `glibc-hello` + `CGO_COMPAT=true`）：

| 项 | 结果 |
| --- | --- |
| 下载吞吐 | ~10 MB/s（阿里云，NAT 出口） |
| 网关 RTT | ~1.5 ms |
| DNS | <1 ms |
| SSH 密钥登录 | `ok`，且 `passwordauthentication=no`、监听 22 |
| VGA（`vpsvga`，qxl） | 抓帧非空，fbterm + 文泉驿字体把业务程序输出渲染上屏 |

VGA 口味没有串口，断言就是抓帧：帧里能看到业务程序的输出（`glibc-hello alive pid=…`）即证明 framebuffer 绑定、fbterm/CJK 字体、app-runner 下载并 exec 业务二进制这条链全通。

## 两个刻意的设计

**initramfs 只装 busybox。** 官方 init 走 `nlplug-findfs`（依赖 libcryptsetup），base 特色还带 `apk`，两者会把整套 OpenSSL/device-mapper 拖进来；换成 busybox 后，独立 `kmod` 又因为支持压缩模块直接依赖 libcrypto。最终做法是自定义 `tiny` 特色 + 只用 busybox 的 `modprobe`/`mdev`，initramfs 从 5.43 MB 降到 3.01 MB。

**app-runner 不用 net/http。** `net/http` 会连带 HTTP/2 和整套 transport 抽象。改成 `crypto/tls` 上手写最小 HTTP/1.1：单流 GET、最多 10 次重定向、chunked 与 Content-Length、读超时 30s 的 stall 看门狗、固定 6 次重试、最小环境变量 `exec`。

**体积由 Go 版本决定，不是编译开关。** 同一份源码用 go1.27.1、`GOAMD64=v3`、`-s -w` 实测：不加任何 `GOEXPERIMENT` 是 4,845,728 字节，只加 `newinliner` 是 4,858,016，当前完整组合是 4,849,824 —— `simd` / `greenteagc` / `sizespecializedmalloc` 对体积没有影响，`newinliner` 反而 +12 KB（换内联质量，保留）。同一源码用 go1.23 编是 4,149,400 字节，那 700 KB 的差距来自 1.24 之后的运行时，调 flags 拿不回来。`-buildid=` 只省 36 字节。

## 约束

- 业务 URL 编译进二进制，不落配置文件。
- 下载不分块、不多线程，失败删临时文件从头再来。
- 业务进程不继承环境变量，只给固定 `PATH`。
- 每个 flavor 的镜像总量（`vpsvga` / `vpsssh`）均以 MB 汇报。
