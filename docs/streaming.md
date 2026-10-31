# Sunshine + Moonlight 串流（VM 桌面/游戏 → Windows 宿主）

在 **Ubuntu VM 内运行 Sunshine**（采集 + 编码），在 **Windows 宿主运行 Moonlight**（解码 + 显示），
绕过 Hyper-V 基本会话的显示通道瓶颈（1080p 全屏 3D 画面会塞满 VMBus，导致整机"假死"）。

> 本机实测（2026-10-31）：Sunshine `2026.914.233613` + Moonlight `6.2.0`，720p/30fps 视频流建立成功，
> 宿主 FFmpeg/D3D11 硬解，音频包正常接收。

---

## 1. 环境事实

| 组件 | 位置 | 版本 |
|---|---|---|
| Sunshine | Ubuntu VM（用户服务） | 2026.914.233613（Cloudsmith apt 源） |
| Moonlight | Windows 宿主 | 6.2.0（winget: `MoonlightGameStreamingProject.Moonlight`） |
| 采集 | KMS（`capture = kms`，因 portal 的 dma-buf 导入在 D3D12 EGL 下不可用） | - |
| 编码 | libx264（软件，`sw_preset = ultrafast`） | - |
| 配对 | 已配对，状态保存在 VM 的 `~/.config/sunshine/sunshine_state.json` | - |

VM 内 Web 管理界面：`https://<VM_IP>:47990`（账号 `admin` / 密码 `Sunshine@2026`，建议首次登录后修改）。
Moonlight 连接地址：`172.20.206.161`（Hyper-V Default Switch，DHCP 可能变；也可用 mDNS 名称）。

---

## 2. 安装（可复用）

> 本机 GitHub 直连被网络策略阻断，因此 Sunshine 通过 **LizardByte 官方 Cloudsmith apt 源**安装；
> Moonlight 通过 winget（安装包走 GitHub 但 winget 缓存可用）。

### 2.1 VM 内安装 Sunshine

```bash
# 添加 Cloudsmith 源（若 setup 脚本写出的 sources 为空，手工写文件）
curl -1sLf -o /tmp/lb-setup.sh 'https://dl.cloudsmith.io/public/lizardbyte/stable/setup.deb.sh'
sudo -E bash /tmp/lb-setup.sh

# 若 /etc/apt/sources.list.d/lizardbyte-stable.list 为空，手工修复：
echo 'deb [signed-by=/usr/share/keyrings/lizardbyte-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/lizardbyte/stable/deb/ubuntu jammy main' | \
  sudo tee /etc/apt/sources.list.d/lizardbyte-stable.list

# 网络不稳时可在宿主机下载 deb 后 scp 进 VM：
# https://dl.cloudsmith.io/public/lizardbyte/stable/deb/ubuntu/pool/jammy/main/s/su/sunshine_2026.914.233613-1+ubuntu22.04/sunshine_2026.914.233613-1+ubuntu22.04_amd64.deb
sudo apt-get update && sudo apt-get install -y sunshine

# 必需：Qt Wayland 平台插件（否则内嵌托盘初始化失败导致进程退出）
sudo apt-get install -y qt6-wayland
```

### 2.2 配置（VM）

```bash
# ~/.config/sunshine/sunshine.conf
cat > ~/.config/sunshine/sunshine.conf <<'EOF'
capture = kms
sw_preset = ultrafast
min_log_level = info
EOF

# systemd 用户服务覆盖（Qt 走 Wayland；强制 llvmpipe EGL 以支持 dma-buf 导入）
mkdir -p ~/.config/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d
cat > ~/.config/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d/override.conf <<'EOF'
[Service]
Environment=QT_QPA_PLATFORM=wayland
Environment=WAYLAND_DISPLAY=wayland-0
Environment=GALLIUM_DRIVER=llvmpipe
Environment=LIBGL_ALWAYS_SOFTWARE=1
EOF

systemctl --user daemon-reload
systemctl --user enable --now app-dev.lizardbyte.app.Sunshine.service
```

> **关键坑**：Sunshine 在 Wayland 下自动采集会卡在 xdg-desktop-portal 授权框；
> 且默认 EGL 上下文是 D3D12（GPU-PV），缺少 `EGL_EXT_image_dma_buf_import`，采集帧导入失败
> （日志 `Couldn't import RGB Image: 00003003` / `Missing extension: [EGL_EXT_image_dma_buf_import]`）。
> 本方案用 `capture = kms` + 强制 llvmpipe 绕开。

### 2.3 宿主安装 Moonlight

```powershell
winget install --id MoonlightGameStreamingProject.Moonlight -e --accept-source-agreements --accept-package-agreements
```

安装位置：`C:\Program Files\Moonlight Game Streaming\Moonlight.exe`。

### 2.4 配对

```powershell
# 宿主：发起配对（PIN 任意 4 位数字）
& 'C:\Program Files\Moonlight Game Streaming\Moonlight.exe' pair 172.20.206.161 --pin 1234
```

Sunshine 侧需批准同一 PIN，任选其一：

```bash
# VM 内：Web UI 输入 PIN（https://<VM_IP>:47990 → PIN 框），或
# 无头模式：sunshine -0 从 stdin 读 PIN（yes 1234 | sunshine -0 capture=kms）
```

> 本机已完成配对。配对后 `moonlight list 172.20.206.161` 应列出
> `Desktop` / `Low Res Desktop` / `Steam Big Picture`。

---

## 3. 日常使用

1. 打开开始菜单 → **Moonlight Game Streaming**
2. 选择主机 **suceru-Virtual-Machine**（已配对；若不在列表，手动添加 `172.20.206.161`）
3. 点 **Desktop** 开始串流（整个 VM 桌面）；也可先串流再在 VM 里启动游戏
4. 串流期间**关闭 Hyper-V 的 VMConnect 窗口**（减少 VMBus 显示通道占用，避免卡顿）

命令行方式（测试/脚本用）：

```powershell
& 'C:\Program Files\Moonlight Game Streaming\Moonlight.exe' stream 172.20.206.161 'Desktop' --720 --fps 30 --bitrate 6000 --display-mode windowed --no-vsync
& 'C:\Program Files\Moonlight Game Streaming\Moonlight.exe' quit 172.20.206.161
```

建议参数：**720p + 30~60fps + 6~10Mbps**（软件编码，1080p60 对 VM CPU 压力大）。

---

## 4. 已知问题 / 注意

1. **鼠标光标可能不可见**：KMS 采集没有 cursor plane（日志 `No KMS cursor plane found`），
   光标可能不出现在串流画面中；可用 `--absolute-mouse` 试试，或靠界面反馈操作。
2. **音频**：测试中已收到音频包；若无声，检查 VM 内 PulseAudio 是否有可用 sink。
3. **CPU 占用**：编码为软件 libx264（4~8Mbps 设置时 Sunshine 约 50~80% 单核等效）。
4. **分辨率**：VM 桌面为 1920×1080；串流 720p 会缩放。也能 1080p 但帧率/延迟会变差。
5. **游戏**：先串流桌面、再在 VM 里启动游戏；Survivalcraft 建议从文件管理器启动
   （避免终端里的 `GALLIUM_DRIVER=d3d12` 触发 GPU-PV 的 `-75` 崩溃，见 troubleshooting 第 13 节）。
6. **停用/恢复**：
   ```bash
   systemctl --user stop app-dev.lizardbyte.app.Sunshine.service    # 停
   systemctl --user start app-dev.lizardbyte.app.Sunshine.service   # 开
   ```
   服务已 enable，图形会话启动时自动运行；配对信息重启保留。
7. **Web UI 凭据**：`admin` / `Sunshine@2026`，建议在 `https://<VM_IP>:47990` 里修改。
8. **网络变化**：VM 用 DHCP，IP 变化后 Moonlight 需重新添加主机（或用 mDNS 名称 `suceru-Virtual-Machine.local`）。

---

## 附：无 GPU-PV / 纯软件渲染模式（X11 会话）

如果 VM **没有** GPU-PV（原始图形状态，Mesa llvmpipe 软件渲染），串流同样可用，但配置不同：

### 事实

- 此模式下 Ubuntu 会话是 **GNOME on Xorg（X11）**（`loginctl show-session ... -p Type` = `x11`，`DISPLAY=:0`）
- 用 **X11 采集**（`capture = x11`），比 KMS/portal 稳，且**鼠标光标正常显示**
- 关闭 Qt 系统托盘：`system_tray = false`（否则需要 Qt xcb/wayland 平台插件，容易启动失败）
- 编码仍是软件 libx264；1080p 桌面建议客户端用 720p/30fps 串流

### 配置

```bash
# ~/.config/sunshine/sunshine.conf
capture = x11
system_tray = false
sw_preset = ultrafast
min_log_level = info
```

```ini
# ~/.config/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d/override.conf
[Service]
Environment=DISPLAY=:0
Environment=XAUTHORITY=/run/user/1000/gdm/Xauthority
```

> Xauthority 路径从 `ps -o args= -C Xorg` 的 `-auth` 参数获取（GDM 会放在 `/run/user/1000/gdm/Xauthority`）。

### 安装来源

该模式通过 **LizardByte 官方 Cloudsmith apt 源**安装（GitHub 直连受限时可用），
或宿主机下载 deb 后 scp 进 VM 用 `apt-get install ./sunshine.deb` 离线安装（依赖从 Ubuntu 源补齐）。

### 配对

```powershell
# 宿主
& 'C:\Program Files\Moonlight Game Streaming\Moonlight.exe' pair <VM_IP> --pin 1234
```

```bash
# VM 内：以无头模式从 stdin 读 PIN 完成配对
yes 1234 | sunshine -0
```

配对成功后 `moonlight list <VM_IP>` 应返回 `Desktop` 等应用列表。

### 已知修复：Moonlight 串流中「鼠标能动但键盘无反应」

**现象**：X11 会话下串流，鼠标移动正常但键盘按键无效。
**原因**：Xorg 通过 systemd-logind 拿不到 `libvirtualhid Keyboard` 设备：

```
(EE) systemd-logind: failed to take device /dev/input/event2: No such device
(II) event2: opening input device '/dev/input/event2' failed (Permission denied).
(EE) libinput: libvirtualhid Keyboard: Failed to create a device for /dev/input/event2
```

**修复**（实测有效）：

```bash
# 1) 让正在运行 Xorg 的用户有权限直接打开 input 设备
sudo usermod -aG input <your-user>
# 2) 重启图形会话，让 Xorg 以新组权限启动（Sunshine 会在新会话自动启动）
sudo systemctl restart gdm3
```

修复后 `xinput list` 应出现：

```
↳ libvirtualhid Keyboard    id=11 [slave keyboard (3)]
```

Xorg 日志出现 `libinput: libvirtualhid Keyboard: is a virtual subdevice` / `Adding extended input device ... (type: KEYBOARD)` 即为成功。
之后 Moonlight 重新连接即可正常使用键盘。该权限对重启持久有效。

