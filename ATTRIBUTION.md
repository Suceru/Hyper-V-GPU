# 第三方来源与许可说明

本仓库是**方案记录与脚本重写**，不包含 Microsoft、AMD、NVIDIA、Intel、Mesa 或 ExHyperV 的二进制文件。

## 运行时下载的第三方组件（不随仓库分发）

| 组件 | 来源 | 许可 |
|---|---|---|
| `dxgkrnl-{5.15,6.6,6.12}-patched.tar.gz` | [Justsenger/ExHyperV · kernel-assets](https://github.com/Justsenger/ExHyperV/tree/kernel-assets)（由 [microsoft/WSL2-Linux-Kernel](https://github.com/microsoft/WSL2-Linux-Kernel) 的 `drivers/hv/dxgkrnl` 打补丁） | GPL-2.0 |
| `libd3d12.so` / `libd3d12core.so` / `libdxcore.so` | [Justsenger/ExHyperV · src/Linux/lib/x64](https://github.com/Justsenger/ExHyperV/tree/main/src/Linux/lib)（源自 Microsoft WSL） | 微软专有组件，仅在本机部署使用 |
| 显卡 Windows UMD（如 `amdxc64.dll`） | 宿主 `C:\Windows\System32\DriverStore\FileRepository` | 显卡厂商驱动许可 |
| Mesa / Dozen / d3d12 驱动 | Ubuntu 软件源 + [Kisak PPA](https://launchpad.net/~kisak/+archive/ubuntu/turtle) | MIT 等开源许可 |

## 脚本来源

`guest/*.sh` 的部署流程参考并改写了 [Justsenger/ExHyperV](https://github.com/Justsenger/ExHyperV) 的 Linux GPU-PV 自动部署脚本，
该项目采用 **GPL-3.0**。本仓库 `guest/` 目录下的脚本按 GPL-3.0 发布，以保持兼容。
`host/*.ps1`、`tools/ssh-runner.py`、文档为本仓库原创（GPL-3.0 / CC BY 4.0）。

## 免责声明

- 微软官方不支持在 Windows 客户端（Win10/11 Pro）上为任意 Linux VM 提供 GPU-PV/DDA；本方案为社区实验路线。
- 使用本仓库内容造成的任何系统不稳定、数据丢失或硬件问题，由使用者自行承担。
