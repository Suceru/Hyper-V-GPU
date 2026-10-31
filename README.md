# Hyper-V Ubuntu 22.04 GPU-PV 接入方案（与 Windows 共享单卡 GPU）

让 Hyper-V 里的 **Ubuntu 22.04 LTS 虚拟机**通过 **GPU-PV（GPU 分区 / 半虚拟化）** 使用 Windows 宿主机上的独立显卡，
**宿主桌面继续正常使用同一张显卡**（无需第二块卡、无需 DDA 直通、无需 WSL）。

> 本仓库记录一套已在真实机器上跑通并验证的方案（2026-10-31）：脚本 + 部署报告 + 踩坑记录，便于下次同场景复用。
> ⚠️ **非官方支持方案**：微软官方 GPU-P 仅支持 Windows Server 2025 + NVIDIA 认证卡，且明确不支持客户端 Windows 上的 DDA/GPU-P；
> Linux 客机需要社区 `dxgkrnl` 路线，属实验性配置，请自行评估稳定性风险。

---

## 1. 实测环境与结果

| 项目 | 值 |
|---|---|
| 宿主 | Windows 11 Pro 25H2（build 26200.9711） |
| CPU | Intel Core i5-13600K |
| GPU | **AMD Radeon RX 7900 XTX**（Navi 31，`1002:744c`，驱动 32.0.31021.5001），单卡，宿主桌面正在使用 |
| 虚拟机 | Hyper-V Gen2 `Ubuntu 22.04 LTS`，8GB 静态内存，Secure Boot 关闭 |
| 客机内核 | `5.15.0-27-generic`（Ubuntu 22.04 GA） |
| 图形栈 | Ubuntu Mesa 23.2.1（`d3d12_dri.so`）+ Kisak Mesa 25.0.7（`dzn_icd` / Dozen） |
| **结果** | OpenGL 4.2：`D3D12 (AMD Radeon RX 7900 XTX)`（`Accelerated: yes`）<br>Vulkan：`Microsoft Direct3D12 (AMD Radeon RX 7900 XTX)`，`driverName = Dozen`<br>`glxgears` ≈ 147 FPS；宿主 2560×1440 显示不受影响；**重启后自动生效** |

> 注：方案对 NVIDIA / Intel 显卡同样适用（同样走 dxgkrnl + Mesa d3d12/dzn），本仓库在 AMD 单卡环境实测。

---

## 2. 原理

```
VM 内应用 (OpenGL / Vulkan / 视频硬解)
   └─ Mesa 23.2.1 (gallium d3d12)  /  Mesa 25.0.7 Dozen (Vulkan-on-D3D12)
        └─ libd3d12.so / libd3d12core.so / libdxcore.so     (/usr/lib/wsl/lib)
             └─ GPU 厂商的 Windows UMD（如 AMD: amdxc64.dll）(/usr/lib/wsl/drivers)
                  └─ /dev/dxg  (dxgkrnl.ko, DKMS 编译)
                       └─ VMBus 半虚拟化通道
                            └─ 宿主 dxgkrnl + 厂商 Windows 驱动
                                 └─ 物理 GPU  ←── 宿主桌面同时使用
```

关键点：
- 显卡驱动把 GPU 暴露为「可分区设备」（`Get-VMHostPartitionableGpu` 可见，GPUPARAV 接口）；
- Hyper-V 给 VM 挂一个 GPU 分区适配器（`Add-VMGpuPartitionAdapter`）；
- 客机里通过 DKMS 编译微软的 `dxgkrnl`（来源：WSL2 内核树），把 D3D12/Dozen 的渲染指令经 VMBus 送到宿主驱动执行；
- 客机**不出现** `amdgpu` 原生驱动，因此 **ROCm/CUDA 计算不走这条路**（本方案面向图形/图形应用）。

---

## 3. 前置条件清单

- [ ] Windows 10 21H2+ 或 Windows 11（客户端版可跑，但官方不支持）
- [ ] Hyper-V 已启用（`vmms` 服务运行）
- [ ] 显卡可分区：管理员 PowerShell 执行 `Get-VMHostPartitionableGpu` 能看到显卡（否则先升级显卡驱动）
- [ ] 虚拟机为 **Gen2**、**Secure Boot 关闭**、**动态内存关闭（建议静态内存）**、**无检查点**
- [ ] 客机 Ubuntu 22.04 LTS（本方案验证版本；22.04 默认 5.15 内核可直接用预编译补丁包）
- [ ] 客机能联网 apt，或使用国内镜像（脚本支持 `USE_CN_MIRROR=1`）
- [ ] 客机有 SSH（推荐，方便自动化；没有也可以手动在控制台执行）

---

## 4. 快速开始

### 4.0 主机侧检查

```powershell
cd host
.\01-host-precheck.ps1 -VMName "Ubuntu 22.04 LTS"
```

确认：可分区 GPU 数量 ≥ 1；VM 处于 Off；Secure Boot 关闭。

### 4.1 主机侧配置（VM 必须处于关机状态）

```powershell
.\02-host-prep.ps1 -VMName "Ubuntu 22.04 LTS"    # 关闭自动检查点 + 设置 MMIO + 挂载 GPU 分区适配器
.\03-start-vm.ps1  -VMName "Ubuntu 22.04 LTS"    # 启动 VM 并等待 IP
```

### 4.2 准备离线资源（主机，可选但推荐）

```powershell
.\fetch-assets.ps1       # 下载 dxgkrnl 预补丁源码（5.15/6.6/6.12）+ 微软 Linux D3D12 库
.\make-driver-pack.ps1   # 把本机 GPU 驱动目录打包成 driver-pack.tar.gz
```

产物：`assets/`、`lib/`、`driver-pack.tar.gz`。若客机能直接访问 GitHub，也可在客机内执行 `fetch-assets` 等价命令（见脚本注释）。

### 4.3 传输到客机

```bash
# 主机执行：把脚本和资源放进 VM 的 ~/gpu-pv
scp -r guest/*.sh assets lib driver-pack.tar.gz 用户@<VM_IP>:~/gpu-pv/
```

### 4.4 客机内执行（按顺序）

```bash
cd ~/gpu-pv && chmod +x *.sh

sudo ./00-install-deps.sh                          # 编译依赖
sudo ./01-graphics-stack.sh                        # Mesa D3D12 + Dozen（国内加速：USE_CN_MIRROR=1）
sudo DEPLOY_DIR=$HOME/gpu-pv ./02-dxgkrnl-deploy.sh  # dxgkrnl DKMS + 注入 D3D12 库与驱动
sudo DEPLOY_DIR=$HOME/gpu-pv ./03-post-config.sh     # 环境变量/工具/GNOME 兼容修复
sudo reboot
```

> `02` 会按当前内核自动选择 5.15 / 6.6 / 6.12 预补丁包；`03` 会安装 `gpu-run`、`gpu-check` 并重启 GDM。

### 4.5 重启后验证

```bash
gpu-check
```

期望输出：

```
OpenGL renderer string: D3D12 (AMD Radeon RX 7900 XTX)
deviceName = Microsoft Direct3D12 (AMD Radeon RX 7900 XTX)
driverName = Dozen
```

---

## 5. 日常使用

| 场景 | 方法 |
|---|---|
| 终端里启动程序 | 直接运行，如 `blender`（登录 shell 已自动设置 GPU 环境变量） |
| 桌面图标 / 菜单启动 | 用 `gpu-run` 包装，如 `gpu-run blender`；或把 `.desktop` 的 `Exec=` 改成 `Exec=gpu-run 原命令` |
| 验证状态 | `gpu-check` |
| 视频硬解 | 环境变量 `LIBVA_DRIVER_NAME=d3d12` 已配置，可用 `vainfo` 验证 |
| 高分辨率/高刷/游戏串流 | Hyper-V 控制台上限 1080p/60Hz；建议 VM 内装 **Sunshine**，主机用 **Moonlight** 串流 |
| Hyper-V 增强会话（xrdp/RDP） | 独立会话，支持剪贴板/音频/自适应分辨率；**没有 GPU-PV 加速**。若登录框怎么选/黑屏，见 [troubleshooting 第 11 节](docs/troubleshooting.md) |
| 切回控制台桌面 | VMConnect 工具栏/「视图」菜单里关闭「增强会话」即回到基本会话（GPU 加速生效的那个桌面） |
| 基本会话分辨率（全屏不跟随） | 基本会话分辨率固定（默认 1024×768），全屏只放大画面不改 guest。运行 `python3 guest/set-resolution.py` 可切到 1920×1080 并持久化（详见 troubleshooting 第 12 节） |

> 说明：GNOME 合成器（桌面本身）运行在**软件渲染 llvmpipe**，**应用层**是硬件加速——这是 22.04 上的稳定取舍（原因见坑 1）。

---

## 6. 已知坑（详细修复见 [docs/troubleshooting.md](docs/troubleshooting.md)）

1. **GNOME 重启后黑屏**：不要把 `GALLIUM_DRIVER=d3d12` 放进 `/etc/environment`。GNOME 合成器会在 GPU 模块就绪前尝试 D3D12 渲染而崩溃。本方案放在 `/etc/profile.d/gpu-pv.sh` + `~/.bashrc`。
2. **客机 DNS 被宿主代理劫持**：宿主用 Clash 等 TUN/fake-IP 模式时，VM 会解析出 `198.18.x.x` 导致 apt 超时。改 `/etc/resolv.conf` 为 `223.5.5.5` / `1.1.1.1`。
3. **内核升级后 GPU 失效**：DKMS 需要对应 `linux-headers-*`。升级内核并重启后执行 `gpu-check`；失败则 `sudo apt install linux-headers-$(uname -r) && sudo dkms autoinstall && sudo reboot`。
4. **宿主显卡驱动更新后**：`/usr/lib/wsl/drivers` 里的 UMD 可能过期。重新执行 `make-driver-pack.ps1` 并重跑 `02` 的驱动部署步骤。
5. **检查点**：GPU-PV VM 不支持检查点。关闭自动检查点，并删除已有检查点（**不要回滚**到部署前检查点，否则客机驱动丢失需重装）。
6. **Secure Boot**：必须关闭，dxgkrnl 是未签名 DKMS 模块。
7. **Vulkan 是 Dozen 翻译层**（Vulkan→D3D12），非原生驱动，个别程序可能不兼容或性能一般。
8. **Hyper-V 增强会话（xrdp）**：xrdp 的 `startwm.sh` 会 source `/etc/profile`，GPU 环境变量必须以「交互式 shell 且非 XRDP 会话」为条件导出（本仓库脚本已内置 guard）；且实测 **增强会话（GNOME on Xorg）会与自动登录的控制台 GNOME 会话冲突**，登录后只剩青色背景。需要 GPU 桌面请只用基本会话，并 `sudo systemctl stop xrdp xrdp-sesman && sudo systemctl restart gdm3`。详见 [troubleshooting 第 11 节](docs/troubleshooting.md)。
9. **磁盘**：客机根分区建议 ≥ 20GB（Mesa + 驱动包 + 编译约需 2GB 余量）。

---

## 7. 维护

- **内核升级**：`gpu-check` → `lsmod | grep dxgkrnl`、`ls /dev/dxg`；必要时 `sudo dkms status` / `sudo dkms autoinstall`。
- **显卡驱动更新**：重新打包驱动并覆盖 `/usr/lib/wsl/drivers`，或重跑 `02-dxgkrnl-deploy.sh`。
- **延迟加载服务**：`systemctl status load-dxg-late.service`；模块由该服务在 `graphical.target` 之后加载，避免和 GNOME 启动竞争。

---

## 8. 回滚

主机（管理员 PowerShell）：

```powershell
Remove-VMGpuPartitionAdapter -VMName "Ubuntu 22.04 LTS"
Set-VM -Name "Ubuntu 22.04 LTS" -GuestControlledCacheTypes $false `
       -LowMemoryMappedIoSpace 128MB -HighMemoryMappedIoSpace 512MB
```

客机：

```bash
sudo dkms remove dxgkrnl/custom --all
sudo rm -rf /usr/lib/wsl /usr/local/bin/gpu-run /usr/local/bin/gpu-check
sudo rm -f /etc/profile.d/gpu-pv.sh /etc/systemd/system/load-dxg-late.service \
           /etc/modprobe.d/blacklist-dxgkrnl.conf /etc/modules-load.d/vgem.conf
sudo systemctl daemon-reload && sudo reboot
```

---

## 9. 仓库结构

```
Hyper-V-GPU/
├── README.md
├── host/
│   ├── 01-host-precheck.ps1   # 检查 GPU 可分区性 / VM 条件
│   ├── 02-host-prep.ps1       # 关闭检查点、MMIO、挂 GPU 分区适配器
│   ├── 03-start-vm.ps1        # 启动 VM 并等待 IP
│   ├── fetch-assets.ps1       # 下载 dxgkrnl 预补丁源码 + Linux D3D12 库
│   └── make-driver-pack.ps1   # 打包本机 GPU 驱动目录
├── guest/
│   ├── 00-install-deps.sh
│   ├── 01-graphics-stack.sh   # Mesa D3D12 + Kisak Dozen Vulkan
│   ├── 02-dxgkrnl-deploy.sh   # DKMS dxgkrnl + 库/驱动注入 + 延迟加载
│   ├── 03-post-config.sh      # 环境变量（防黑屏）/gpu-run/gpu-check/GDM
│   ├── gpu-check.sh
│   ├── gpu-run
│   └── set-resolution.py      # 基本会话切 1920x1080（持久化）
├── tools/
│   └── ssh-runner.py          # 可选：SSH 批量执行/上传脚本
├── docs/
│   ├── case-study-2026-10-31.md  # 本次实机部署报告（含验证数据）
│   └── troubleshooting.md        # 已知问题与修复
└── ATTRIBUTION.md
```

---

## 10. 参考与许可

- 本方案的 Linux GPU-PV 部署流程基于 [Justsenger/ExHyperV](https://github.com/Justsenger/ExHyperV)（**GPL-3.0**）的 Linux 部署逻辑改写，并按本机环境实测修正；预补丁内核源码与 Linux D3D12 库运行时从该仓库下载，**不随本仓库分发二进制**。
- `dxgkrnl` 来源：[microsoft/WSL2-Linux-Kernel](https://github.com/microsoft/WSL2-Linux-Kernel)。
- Mesa/Kisak PPA：<https://launchpad.net/~kisak/+archive/ubuntu/turtle>
- 微软官方文档（客户端不受支持，务必知悉）：
  - <https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/troubleshoot-hyper-v-gpu-assignment-partitioning-passthrough-issues>
  - <https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/plan/plan-for-deploying-devices-using-discrete-device-assignment>
- 许可：`guest/` 脚本为 GPL-3.0（与上游 ExHyperV 兼容）；文档 CC BY 4.0。使用风险自负。
