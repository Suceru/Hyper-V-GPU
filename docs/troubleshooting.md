# 已知问题与修复（Troubleshooting）

本文按「现象 → 原因 → 修复」组织，均为 2026-10-31 实机部署中实际遇到或验证过的问题。

---

## 1. 重启后 GNOME 黑屏 / 桌面起不来

**现象**：部署完成重启后，VM 控制台黑屏或停在登录界面之后；SSH 能进，`systemctl status gdm3` 显示 active，但 `ps aux | grep gnome-shell` 没有进程；`journalctl -b -p 3` 里有：

```
Failed to start GNOME Shell on Wayland.
Failed to start Application launched by gnome-session-binary.
```

**原因**：`GALLIUM_DRIVER=d3d12` 被写入 `/etc/environment`（全局，PAM 对所有会话生效）。
GNOME Shell 启动时 GPU-PV 的 `dxgkrnl` 还没由延迟加载服务就绪，或 GNOME 合成器的 EGL/GBM 与 Mesa d3d12 不兼容 → 启动失败。
这是 Ubuntu 22.04 + GPU-PV 的已知问题（24.04 的 GNOME 已修复）。

**修复**：把 GPU 环境变量从全局移出，仅给交互式 shell；GNOME 合成器保持 llvmpipe：

```bash
sudo sed -i '/^GALLIUM_DRIVER=/d;/^DRI_PRIME=/d;/^LIBVA_DRIVER_NAME=/d' /etc/environment
sudo tee /etc/profile.d/gpu-pv.sh >/dev/null <<'EOF'
export GALLIUM_DRIVER=d3d12
export DRI_PRIME=1
export LIBVA_DRIVER_NAME=d3d12
EOF
sudo systemctl restart gdm3
```

本仓库的 `guest/03-post-config.sh` 已内置该修复。

> 注意：**不要**再用「卸载/重新挂载 GPU 分区适配器」的老办法救急，容易在重启时造成更多问题。

---

## 2. 客机 apt 全部超时 / 解析到 198.18.x.x

**现象**：

```
无法连接 archive.ubuntu.com:80 (198.18.0.6)，连接超时
```

**原因**：宿主使用 Clash/Mihomo 等 TUN + fake-IP 模式，DNS 对所有查询返回 `198.18.0.0/15` 假地址；
Hyper-V Default Switch 的 NAT 客机侧无法访问宿主的 Clash 路由 → 超时。`getent hosts` 也会显示 198.18.x.x（但真实 IP 流量其实是通的）。

**修复**：在客机里把 DNS 换成真实公共 DNS：

```bash
sudo sh -c 'printf "nameserver 223.5.5.5\nnameserver 1.1.1.1\n" > /etc/resolv.conf'
# 如果 /etc/resolv.conf 是 systemd-resolved 的符号链接，先 rm 再写
sudo apt-get update
```

国内环境可同时换 apt 镜像（`guest/01-graphics-stack.sh` 支持 `USE_CN_MIRROR=1`）。

---

## 3. dxgkrnl 编译失败 / `dkms build` 报错

**现象**：`dkms build dxgkrnl/custom` 失败，提示找不到内核头文件或版本不匹配。

**原因**：

- `/lib/modules/$(uname -r)/build` 不存在（缺 `linux-headers-$(uname -r)`）；
- 内核版本与预补丁包不匹配（22.04 默认 5.15 → 用 5.15 包；HWE 6.8 → 脚本会选 6.12 包，部分内核可能需要额外验证）。

**修复**：

```bash
sudo apt install linux-headers-$(uname -r)
# 确认脚本自动选包正确：
#   5.x      -> dxgkrnl-5.15-patched.tar.gz
#   6.0~6.6  -> dxgkrnl-6.6-patched.tar.gz
#   6.7+     -> dxgkrnl-6.12-patched.tar.gz
sudo DEPLOY_DIR=$HOME/gpu-pv ./02-dxgkrnl-deploy.sh
```

若确实编译不过，可改用 22.04 的 GA 5.15 内核（安装 `linux-image-5.15.0-xx-generic` 与 headers 后重启选择）。

---

## 4. 重启后 `/dev/dxg` 不存在 / GPU 加速失效

排查顺序：

```bash
uname -r
lsmod | grep dxgkrnl                      # 模块是否加载
ls -l /dev/dxg                            # 设备节点
systemctl status load-dxg-late.service    # 延迟加载服务
sudo dmesg | grep -i dxg | tail -20
dkms status
```

- 模块未编译进当前内核 → 检查 DKMS 与 headers（见上一条）；
- `modprobe: FATAL: Module dxgkrnl not found` → `dkms status` 无记录，重跑 02 脚本；
- 服务没跑 → `sudo systemctl enable --now load-dxg-late.service`，并确认 `graphical.target` 下已 enable。

---

## 5. 宿主显卡驱动 / Windows 更新后 GPU 加速失效

**原因**：`/usr/lib/wsl/drivers` 里的厂商 UMD 与宿主新驱动版本不匹配。

**修复**（主机侧重新打包 + 客机覆盖）：

```powershell
# 主机
.\make-driver-pack.ps1
scp driver-pack.tar.gz 用户@<VM_IP>:~/gpu-pv/
```

```bash
# 客机
sudo rm -rf /usr/lib/wsl/drivers/*
sudo tar -xzf ~/gpu-pv/driver-pack.tar.gz -C /usr/lib/wsl/drivers
sudo chmod -R 0555 /usr/lib/wsl; sudo ldconfig
# 重启 VM
```

---

## 6. 检查点 / 快照问题

GPU-PV 的 VM **不支持检查点**。若创建检查点会报错或导致异常。

- 关闭自动检查点：`Set-VM -Name "<VM>" -AutomaticCheckpointsEnabled $false`
- 删除已有检查点（VM 关机后）：`Get-VMSnapshot -VMName "<VM>" | Remove-VMSnapshot`
- **不要回滚到部署前的检查点**：宿主 GPU 分区适配器仍在，但客机内驱动丢失，需要重新执行客机部署脚本。

---

## 7. 桌面/应用还是软件渲染（llvmpipe）

- GNOME 桌面合成器**本来就是** llvmpipe（设计取舍，见坑 1）；判断应用是否加速要看应用自身的 OpenGL/Vulkan 报告；
- 从桌面图标启动的程序不会自动继承 GPU 环境变量 → 用 `gpu-run <程序>` 启动；
- 终端里执行 `DISPLAY=:0 glxinfo -B | grep renderer`，显示 `D3D12 (…)` 即为加速；
- 若显示 `llvmpipe`：检查是否漏了 `GALLIUM_DRIVER=d3d12`、`/dev/dxg` 是否存在、当前用户是否在 `video/render` 组。

---

## 8. 分辨率 / 帧率上不去（控制台 1080p60 限制）

Hyper-V 基本会话的虚拟显示上限约 1080p/60Hz，与 GPU 无关。方案：

1. **Sunshine + Moonlight 串流**（推荐）：VM 内安装 Sunshine，宿主用 Moonlight 连；
2. 增强会话（xrdp）：支持更高分辨率但走 RDP 编码，不适合高帧率；
3. 虚拟显示器驱动（如 Virtual-Display-Driver）+ 串流，自定高分辨率/高刷。

---

## 9. Vulkan 程序兼容性 / 性能问题

客机 Vulkan 来自 Mesa 的 **Dozen（dzn）**，是 Vulkan→D3D12 的翻译层，并非原生 Vulkan：

- 简单程序、Blender（Vulkan/OpenGL 后端）通常可用；
- 复杂游戏（DXVK/Proton 链路：D3D→Vulkan→D3D12）可能失败或性能一般；
- 想跑 `vulkaninfo` 验证时建议显式指定 ICD：

```bash
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/dzn_icd.x86_64.json vulkaninfo --summary
```

---

## 10. 其他提示

- `dmesg` 中的 `dxgkio_query_adapter_info: Ioctl failed: -22` 是 dxcore 探测可选特性的正常告警，不影响渲染；
- `Dropped Escape call with ulEscapeCode` 是 libd3d12 控制台处理的无害告警；
- VM 关机后再开机，GPU 分区适配器配置会保留；宿主重启/驱动更新后建议先验证宿主 `Get-VMHostPartitionableGpu`；
- 整机回滚见 README 第 8 节。

---

## 11. Hyper-V 增强会话（xrdp / RDP）专题

### 11.1 这个登录框是什么？怎么选？

Hyper-V 虚拟机连接窗口里点「增强会话」后，Linux 客机会通过 **xrdp（RDP 服务）** 弹出登录框：

```
Login to <hostname>   [xrdp logo]
Session  [Xorg ▼]
username [        ]
password [        ]
```

- **Session 选 `Xorg`**（xrdp 的 xorgxrdp 后端，启动 GNOME on Xorg 桌面）；
- username / password 填**客机里的 Linux 用户**（不是 Windows 用户）；
- 点 OK 即可。其它选项（如 `Xvnc`、`console`）一般不用；`console` 会接管物理控制台会话，容易冲突。

### 11.2 增强会话里的桌面和「之前的桌面」不一样？

**这是正常的**：增强会话是**独立的 RDP 登录会话**（xrdp 分配 `DISPLAY=:10`），不是控制台那个 GNOME Wayland 会话（tty2）。
两个会话的应用窗口互不相通；分辨率、剪贴板、音频行为也不同。

- 想回到「之前的桌面」：在 VMConnect 窗口的工具栏/「视图」菜单里**关闭增强会话**，切回**基本会话**（控制台桌面）。
- 控制台桌面才是 GPU-PV 加速生效的会话（`glxinfo` 显示 `D3D12 (GPU)`）。

| | 基本会话（控制台） | 增强会话（xrdp/RDP） |
|---|---|---|
| 桌面 | GNOME Wayland，控制台会话 | GNOME on Xorg，独立 `:10` 会话 |
| GPU-PV 加速 | ✅（应用经 Mesa d3d12/dzn） | ❌（Xorg 会话走软件渲染/llvmpipe） |
| 剪贴板/音频/自适应分辨率 | 有限 | ✅ |
| 适用 | GPU 应用、Blender、游戏串流 | 日常管理、复制粘贴、高分辨率 RDP |

### 11.3 增强会话登录后黑屏 / GNOME 起不来 / 不是正常桌面

**原因**：`/etc/profile.d/gpu-pv.sh` 里的 `GALLIUM_DRIVER=d3d12` 被 xrdp 的 `/etc/xrdp/startwm.sh`（它 source 了 `/etc/profile`）注入到 GNOME 的 **Xorg** 会话，导致 GNOME 合成器初始化失败——与 22.04 上 Wayland 黑屏是同一类问题。

**修复**（本仓库 `guest/03-post-config.sh` 已内置 guard，若手工部署需自行处理）：

```bash
# 1) 环境变量只给交互式 shell，且跳过 xrdp / X 会话
sudo tee /etc/profile.d/gpu-pv.sh >/dev/null <<'EOF'
case $- in
  *i*)
    if [ -z "${XRDP_SESSION:-}" ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
      export GALLIUM_DRIVER=d3d12
      export DRI_PRIME=1
      export LIBVA_DRIVER_NAME=d3d12
    fi
    ;;
esac
EOF
# 2) ~/.bashrc 中同样加 [ -z "$XRDP_SESSION" ] 条件
# 3) 结束旧的 xrdp 会话后重启服务
sudo pkill -f 'Xorg :10'; sudo systemctl restart xrdp xrdp-sesman
```

> ⚠️ 清理 xrdp 会话时**不要**用 `loginctl terminate-session` 批量终止所有用户会话：
> 会连带杀掉 SSH 和控制台会话。只针对 xrdp 的 `:10` 会话处理即可。

### 11.4 增强会话连接失败 / 日志报证书错误

**现象**（`journalctl -u xrdp`）：

```
Cannot read certificate file /etc/xrdp/cert.pem: No such file or directory
Cannot read private key file /etc/xrdp/key.pem: Permission denied
libxrdp_force_read: header read error / MCS Connection Sequence failed
```

**原因**：Ubuntu 的 xrdp 默认把 `/etc/xrdp/{cert,key}.pem` 符号链接到 `ssl-cert-snakeoil`；若该 snakeoil 证书不存在或是坏链接，
TLS 协商失败，Hyper-V 增强会话可能连不上或时好时坏。

**修复**：

```bash
sudo rm -f /etc/xrdp/cert.pem /etc/xrdp/key.pem
sudo openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650   -keyout /etc/xrdp/key.pem -out /etc/xrdp/cert.pem -subj "/CN=$(hostname)"
sudo chown root:xrdp /etc/xrdp/key.pem /etc/xrdp/cert.pem
sudo chmod 640 /etc/xrdp/key.pem && sudo chmod 644 /etc/xrdp/cert.pem
sudo systemctl restart xrdp xrdp-sesman
```

### 11.5 增强会话 vs 自动登录控制台 GNOME：会冲突（本机实测）

本机环境（Ubuntu 22.04 + GDM `AutomaticLoginEnable=true`）实测：**只使用增强会话（xrdp，GNOME on Xorg）时，GNOME 桌面启动失败**：

```
gnome-session-binary: WARNING: software acceleration check failed: Child process exited with code 1
# 随后 journal 中出现
gnome-session-failed --allow-logout
```

现象：RDP 登录成功，但画面只剩 **xrdp 的青色背景**，没有桌面。即使修好环境变量泄漏（11.3）仍然如此；
xorgxrdp 的图形栈与该 VM 的 GPU-PV + 自动登录控制台会话组合不兼容。

**推荐做法（本方案）**：需要 GPU 加速桌面时**只用基本会话**（控制台自动登录桌面）。

```bash
# 停用增强会话，回到基本会话（在客机内执行）
sudo systemctl stop xrdp xrdp-sesman
sudo systemctl reset-failed xrdp xrdp-sesman 2>/dev/null || true
sudo systemctl restart gdm3      # 重建控制台自动登录会话
```

之后在 VMConnect 里重新连接（若提示增强会话不可用，点确定即进入基本会话）。

> 需要增强会话的剪贴板/音频/高分辨率时，改用 RustDesk / Sunshine / VNC 等远程方案，均不影响 GPU 桌面。
> 若确实要长期使用 xrdp 增强会话，建议关闭 GDM 自动登录，并把增强会话作为唯一图形会话（此时无 GPU-PV 加速）。

---

## 12. 基本会话分辨率固定 / 全屏时画面不跟随窗口

**现象**：把 Hyper-V VMConnect 窗口最大化/全屏，VM 里的桌面尺寸不变（画面被放大或在中间留黑边）。

**原因**：这是 **Hyper-V 基本会话的固有限制**——基本会话把 VM 的 framebuffer 按固定分辨率（默认 1024×768）显示，
不会随窗口大小动态修改 guest 分辨率；"窗口跟随缩放 / 自适应分辨率"是 **增强会话（xrdp/RDP）** 的能力，
而增强会话在本方案中因与自动登录 GNOME 冲突而停用（见 11.5），且没有 GPU-PV 加速。

**修复（提高基本会话分辨率）**：Hyper-V 虚拟显卡最多支持 1920×1080。在**客机内**运行：

```bash
python3 guest/set-resolution.py          # 或任意路径下的副本
```

脚本通过 Mutter DisplayConfig D-Bus 接口把 `Virtual-1` 切到 1920×1080@60（持久化写入 `~/.config/monitors.xml`），
立即生效、重启后保持。也可以用图形界面：**设置 → 显示器 → 分辨率 → 1920×1080**。

验证：

```bash
DISPLAY=:0 xrandr | head -2        # 应显示 current 1920 x 1080
cat ~/.config/monitors.xml         # 持久化配置
```

之后把 VMConnect 窗口最大化/全屏查看即可（1080p 在 2K/4K 屏幕上 1:1 居中显示）。

**如果想要真正的"自适应窗口尺寸"**：只能走增强会话（无 GPU）或改用 **Sunshine/Moonlight、RustDesk** 等串流/远程工具（保留 GPU 桌面）。

---

## 13. 启动 3D 游戏后整个 VM 像卡死（GPU-PV 兼容性 + 基本会话显示通道瓶颈）

**现象**：在客机里启动 3D 游戏（本例：Survivalcraft 原生 Linux 版），进入地图后整个 VM 像卡住：
鼠标/画面不更新、SSH 频繁掉线；但宿主机上 VM 进程与 GPU 分区仍活跃。

**实测证据（2026-10-31）**：

```bash
# 1) 游戏进程确实走了 GPU-PV 的 D3D12 路径
ls -l /proc/<game-pid>/fd | grep dxg          # -> /dev/dxg
grep -oE 'libd3d12[^ ]*|libdxcore[^ ]*' /proc/<game-pid>/maps
# 2) 进入地图时内核报 GPU 虚拟地址分配失败
dmesg -T | grep dxg
#   misc dxg: dxgk: dxgkio_reserve_gpu_va: Ioctl failed: -75   (EOVERFLOW)
# 3) 宿主机 GPU 引擎可看到 VM 的 vmwp.exe 在使用 GPU 分区
Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine | ? Name -like '*phys_0_eng*'
# 4) 游戏卡在重试循环(≈80% CPU)，同时全屏 1080p 帧要走 VMBus 合成显示通道，
#    通道饱和把同一 VMBus 上的虚拟网络也拖慢 -> SSH 掉线、整机“假死”
```

**根因**：

1. GPU-PV 的 D3D12 路径是实验性驱动（Mesa d3d12 / Dozen 翻译层），部分游戏在加载大量纹理/大块显存分配时会触发
   `dxgkio_reserve_gpu_va` 失败（-75），游戏卡在重试循环；
2. Hyper-V **基本会话**的显示输出经 VMBus 搬送 framebuffer，全屏 1080p 的高帧率画面会占满该通道
   （连虚拟网卡都受影响），所以看起来“整个虚拟机都卡住了”。

**处理**：

```bash
# 1) 恢复：在宿主机经 SSH 直接杀掉卡住的游戏（本次实测有效）
ssh <user>@<vm-ip> "pkill -9 -f Survivalcraft"
# 2) 让该游戏改用软件渲染（绕开 GPU-PV D3D12 路径）
#    - 从文件管理器双击启动（GUI 进程不带 GALLIUM_DRIVER 环境变量），或：
cd ~/sc-linux/linux-x64
env -u GALLIUM_DRIVER -u DRI_PRIME -u LIBVA_DRIVER_NAME ./Survivalcraft
```

**建议**：

- 不要在终端里直接启动游戏（终端 shell 会带 `GALLIUM_DRIVER=d3d12`，必然走 GPU-PV 路径）；
- 软件渲染下建议**窗口化 + 1280×720 左右**分辨率，避免全屏 1080p 打满 VMBus 显示通道；
- 想流畅 3D：用 **Sunshine + Moonlight 串流**（绕过基本会话显示通道，保留 GPU 渲染），或直接在 Windows 宿主上玩；
- 纯桌面/办公使用不受影响（本次卡死仅发生在全屏 3D 游戏）。

