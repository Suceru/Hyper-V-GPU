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
