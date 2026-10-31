> 说明：本文是 2026-10-31 在真实机器上的原始部署报告（含当时的验证输出与主机/客机环境），代码与脚本已同步抽离到本仓库 `host/`、`guest/` 目录。复用时请按 README 的通用步骤操作，案例中的用户名、IP、路径需替换。

# Hyper-V Ubuntu 22.04 GPU 接入报告（GPU-PV / GPU 分区）

- **日期**：2026-10-31
- **主机**：Windows 11 Pro 25H2（build 26200.9711），ASUS 主板，i5-13600K，32GB RAM
- **显卡**：AMD Radeon RX 7900 XTX（Navi 31，PCI `1002:744c`，驱动 32.0.31021.5001）—— 单卡，宿主桌面正在使用（2560×1440）
- **虚拟机**：`Ubuntu 22.04 LTS`，Gen2，配置版本 12.0，8GB 静态内存，内核 `5.15.0-27-generic`
- **结论**：✅ **已接入成功**。VM 内 OpenGL 4.2 与 Vulkan 均已硬件加速，使用同一张 RX 7900 XTX；Windows 宿主桌面完全不受影响，双方同时可用。重启后自动生效。

---

## 一、最终验证结果（VM 内实测）

```text
$ gpu-check
[kernel] 5.15.0-27-generic
[dxgkrnl module] dxgkrnl 172032 4 ; vgem ...
[/dev/dxg] crw-rw-rw- 1 root root 10, 120 /dev/dxg

[OpenGL renderer (D3D12)]
    Accelerated: yes
OpenGL renderer string: D3D12 (AMD Radeon RX 7900 XTX)
OpenGL version string: 4.2 (Compatibility Profile) Mesa 23.2.1

[Vulkan (Dozen)]
deviceName = Microsoft Direct3D12 (AMD Radeon RX 7900 XTX)
driverName = Dozen
driverInfo = Mesa 25.0.7 - kisak-mesa PPA

[late-load service] enabled
```

- `glxgears` 实测：**737 frames in 5.0 seconds = 147.3 FPS**（确认真实渲染，非 llvmpipe）
- 宿主侧：`Win32_VideoController` 仍为 2560×1440、Status OK，Windows 桌面全程正常
- VM 重启后自动恢复：`load-dxg-late.service` 在 graphical.target 后加载模块，`/dev/dxg` 自动出现

---

## 二、方案选择说明

| 方案 | 可行性 | 说明 |
|---|---|---|
| **DDA 直通** | ❌ 不可行 | 微软 DDA 仅限 Windows Server 2016–2025 / Azure Local；官方排障文档（2026-02 更新）明确 "DDA and GPU-P aren't supported on desktop-class hardware or client operating systems such as Windows 10 or 11 Pro"。本机 `Get-VMHostAssignableDevice` 返回 0 个可分配设备。且单卡直通会让宿主失去显示。 |
| **GPU-PV 分区** | ✅ 本次采用 | 唯一满足"宿主 + VM 同时用卡"的路线。主机驱动已将 RX 7900 XTX 暴露为可分区 GPU（`Get-VMHostPartitionableGpu`，GPUPARAV 接口，32 分区）。微软官方仅支持 Windows 客机 / Server 2025 GPU-P；**Linux 客机需社区方案**，本次用 ExHyperV 的 Ubuntu 22.04 部署链并实测通过（AMD 亦然）。 |

> ⚠️ 定位：**实验性、非官方支持配置**。桌面应用/计算类负载可用；对稳定性要求极高的生产环境请慎用。

---

## 三、实现链路

```
VM 内应用 (OpenGL/Vulkan)
   └─ Mesa 23.2.1 (gallium d3d12) / Mesa 25.0.7 Dozen (Vulkan-on-D3D12)
        └─ libd3d12core.so / libd3d12.so / libdxcore.so   (/usr/lib/wsl/lib)
             └─ AMD Windows UMD: amdxc64.dll / amdxx64.dll  (/usr/lib/wsl/drivers)
                  └─ /dev/dxg  (dxgkrnl 2.0.3, DKMS)
                       └─ VMBus 半虚拟化通道
                            └─ 宿主 dxgkrnl + AMD Windows 驱动
                                 └─ Radeon RX 7900 XTX   ← 宿主桌面也在同时使用
```

---

## 四、已做的修改

### 4.1 主机侧（Windows，管理员权限；全部可逆）

```powershell
# 关闭自动检查点（GPU-PV 不支持检查点）
Set-VM -Name "Ubuntu 22.04 LTS" -AutomaticCheckpointsEnabled $false

# 缓存类型 + MMIO 地址空间（24GB 显存卡按 64GB 高 MMIO 配置）
Set-VM -Name "Ubuntu 22.04 LTS" -GuestControlledCacheTypes $true `
       -LowMemoryMappedIoSpace 1GB -HighMemoryMappedIoSpace 64GB

# 添加 GPU-PV 分区适配器（VM 关机状态下执行）
$gpu = Get-VMHostPartitionableGpu | Select-Object -First 1
Add-VMGpuPartitionAdapter -VMName "Ubuntu 22.04 LTS" -InstancePath $gpu.Name
```

- 内存保持静态 8GB（未启用动态内存）
- 未修改宿主显卡驱动、未安装 WSL

### 4.2 客户机侧（Ubuntu 22.04）

1. **网络修复**：VM 的 DNS 继承宿主 Clash 的 fake-IP（198.18.x），客户机不可达 → `/etc/resolv.conf` 固定为 `223.5.5.5 / 1.1.1.1`；apt 源换阿里云镜像。
2. **编译环境**：`build-essential dkms git curl wget unzip software-properties-common`。
3. **图形栈**：
   - Ubuntu jammy-updates Mesa 23.2.1（含 `d3d12_dri.so`）
   - Kisak PPA `ppa:kisak/turtle` → Mesa 25.0.7（含 `dzn_icd`，即 Dozen Vulkan 驱动）
4. **dxgkrnl 内核模块**：ExHyperV 预补丁源码（`dxgkrnl-5.15-patched.tar.gz`）→ `/usr/src/dxgkrnl-custom` → DKMS 编译安装（`dxgkrnl/custom, 5.15.0-27-generic`）。
5. **微软 D3D12 库**：`libd3d12.so`、`libd3d12core.so`、`libdxcore.so` → `/usr/lib/wsl/lib`（含 `libD3D12Core.so` 大小写兼容链接 + ldconfig）。
6. **AMD 驱动注入**：宿主 `DriverStore\FileRepository\u0202082.inf_amd64_61e8e071c4b56ef4`（72 个 DLL）→ `/usr/lib/wsl/drivers/u0202082.inf_amd64_61e8e071c4b56ef4/`。
7. **加载策略**：
   - `vgem` 开机加载（`/etc/modules-load.d/vgem.conf`）
   - `dxgkrnl` 加入 initramfs 黑名单，由 `load-dxg-late.service` 在 `graphical.target` **之后**延迟加载（避免 GNOME 合成器在模块就绪前尝试 D3D12 渲染）
8. **环境变量**：`GALLIUM_DRIVER=d3d12`、`DRI_PRIME=1`、`LIBVA_DRIVER_NAME=d3d12`
   - ⚠️ 只放在 `/etc/profile.d/gpu-pv.sh` 和 `~/.bashrc`（**不进 `/etc/environment`**，否则 GNOME 黑屏，见第六节）
9. **工具**：
   - `/usr/local/bin/gpu-run`：以 GPU 加速启动任意 GUI 程序
   - `/usr/local/bin/gpu-check`：一键自检脚本
10. **SSH 维护通道**：主机公钥 `C:\Users\12464\gpu-pv\id_ed25519` 已加入 `suceru` 的 `~/.ssh/authorized_keys`（VM IP：`172.20.206.161`，Default Switch，DHCP 可能变化）。

---

## 五、使用方法

### 5.1 验证是否正常

VM 内终端执行：

```bash
gpu-check
```

### 5.2 让程序用上 GPU

- **终端里直接运行**（shell 已自动带 GPU 环境变量）：

  ```bash
  blender          # 或 steam、chrome 等
  ```

- **桌面图标启动**（GUI 进程默认不带环境变量）：

  ```bash
  gpu-run blender
  ```

  如需双击图标也加速：复制对应 `.desktop` 文件到 `~/.local/share/applications/`，把 `Exec=` 改成 `Exec=gpu-run 原命令`。

- **视频硬解**：环境变量 `LIBVA_DRIVER_NAME=d3d12` 已设置，`vainfo` 可验证。

### 5.3 关于桌面的说明（重要取舍）

- GNOME 合成器（桌面本身）运行在**软件渲染 llvmpipe** 上；**应用层（OpenGL/Vulkan）硬件加速**。这是 Ubuntu 22.04 上的稳定取舍——若把 `GALLIUM_DRIVER=d3d12` 放进 `/etc/environment`，GNOME Shell 会在重启后黑屏（本次已实际踩坑并修复）。
- 显示输出：Hyper-V 基本会话上限 1080p/60Hz（`hyperv_drm`）。需要高分辨率/高刷新率或玩游戏 → 在 VM 内装 **Sunshine**，主机用 **Moonlight** 串流（ExHyperV 推荐方案）；或增强会话（xrdp）。

---

## 六、已知限制与注意事项

1. **内核升级**：DKMS 会自动为新内核重建（`AUTOINSTALL=yes`），但需要对应的 `linux-headers-*`。升级后请重启并执行 `gpu-check`；若失败：
   ```bash
   sudo apt install linux-headers-$(uname -r)
   sudo dkms autoinstall && sudo reboot
   ```
2. **不要**把 `GALLIUM_DRIVER=d3d12` 写回 `/etc/environment`（会导致 GNOME 黑屏）。
3. **不要创建 VM 检查点**（GPU-PV 不支持）。当前 VM 有 2 个部署前的旧检查点（19:59 / 20:01），**建议关机后删除**；不要回滚到它们——回滚后宿主适配器仍在但客机驱动丢失，需重跑部署脚本。
4. **宿主显卡驱动 / Windows 更新后**：`/usr/lib/wsl/drivers` 里的驱动文件可能过期。更新 AMD 驱动后，重新上传新的 `DriverStore\FileRepository\u*.inf_amd64_*` 目录覆盖即可（原始流程见第四节 4.2 第 6 步）。
5. **磁盘空间**：VM 根分区 12GB，当前剩余约 3.9GB，注意不要塞满。
6. **Vulkan 是 Dozen 翻译层**（Vulkan→D3D12），非原生 Vulkan 驱动；部分游戏/程序可能不兼容或性能一般。OpenGL 4.2 为 D3D12 后端，通用性较好。
7. **实验性质**：极端负载可能触发驱动重置/客机卡死；重启 VM 即可恢复（宿主不受影响）。
8. 官方支持状态：微软仅对 **Windows Server 2025 GPU-P + NVIDIA 认证卡** 提供 Ubuntu 客机官方支持；AMD 消费卡无官方 Hyper-V GPU 分区支持。本方案为社区路线，系统大版本升级后可能失效。
9. `dmesg` 中的 `dxgkio_query_adapter_info: Ioctl failed: -22` 是 dxcore 探测可选特性的正常告警，不影响渲染。

---

## 七、回滚方法

主机（管理员 PowerShell）：

```powershell
Remove-VMGpuPartitionAdapter -VMName "Ubuntu 22.04 LTS"
Set-VM -Name "Ubuntu 22.04 LTS" -GuestControlledCacheTypes $false `
       -LowMemoryMappedIoSpace 128MB -HighMemoryMappedIoSpace 512MB
```

客户机（如需彻底清除）：

```bash
sudo dkms remove dxgkrnl/custom --all
sudo rm -rf /usr/lib/wsl /usr/local/bin/gpu-run /usr/local/bin/gpu-check
sudo rm -f /etc/profile.d/gpu-pv.sh /etc/systemd/system/load-dxg-late.service \
           /etc/modprobe.d/blacklist-dxgkrnl.conf /etc/modules-load.d/vgem.conf
sudo systemctl daemon-reload
sudo apt remove --purge mesa-vulkan-drivers vulkan-tools mesa-utils  # 可选
sudo reboot
```

---

## 八、文件与日志清单

主机 `C:\Users\12464\gpu-pv\`：

| 文件 | 说明 |
|---|---|
| `host-prep.ps1` / `host-prep.txt` | 主机侧 GPU-PV 配置脚本与执行日志 |
| `start-vm.ps1` / `start-vm.txt` | 启动 VM、获取 IP 的脚本与日志 |
| `phase1_graphics.sh` | 客机 Mesa/Dozen/图形栈安装 |
| `phase2_deploy.sh` | 客机 dxgkrnl 编译、D3D12/AMD 驱动注入、系统配置 |
| `fix_gnome.sh` | GNOME 黑屏修复（全局环境变量迁移） |
| `gpu-check.sh` / `gpu-run` | 客机自检与加速启动工具（已安装到 VM） |
| `lib/` | 微软 Linux D3D12 库（3 个 .so） |
| `assets/dxgkrnl-5.15-patched.tar.gz` | 预补丁 dxgkrnl 源码 |
| `driver-pack.tar.gz` | AMD 驱动包（359MB，客机侧已删除，主机保留备查） |
| `id_ed25519(.pub)` | 主机→VM 维护用 SSH 密钥 |
| `*.py` | 本次自动化脚本（可复用） |

客机日志：`/var/log/apt/term.log`、`journalctl -b`、`dmesg | grep dxg`。
客机部署时间线：21:40 上传 → 21:50 Mesa → 21:51 模块加载成功 → 21:53 重启验证 → 21:55 GNOME 修复 → 21:56 最终验证。

---

## 九、参考

- 微软 GPU 分区/直通官方文档（客户端版不受支持）：<https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/troubleshoot-hyper-v-gpu-assignment-partitioning-passthrough-issues>
- 微软 DDA 规划文档（仅 Server）：<https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/plan/plan-for-deploying-devices-using-discrete-device-assignment>
- ExHyperV（Linux GPU-PV 部署脚本来源）：<https://github.com/Justsenger/ExHyperV>
- dxgkrnl 上游（WSL2 内核）：<https://github.com/microsoft/WSL2-Linux-Kernel>
- Kisak Mesa PPA：<https://launchpad.net/~kisak/+archive/ubuntu/turtle>
- 社区参考：<https://gist.github.com/krzys-h/e2def49966aa42bbd3316dfb794f4d6a>、<https://github.com/staralt/dxgkrnl-dkms>
