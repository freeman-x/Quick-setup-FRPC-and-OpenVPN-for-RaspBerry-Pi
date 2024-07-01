### Raspberry Pi 3B OpenVPN 和 FRPC 一键安装脚本

此脚本旨在简化 Raspberry Pi 3B 上 OpenVPN 服务器和 FRPC 客户端的安装与配置过程，并将这些服务设置为开机自启动。通过运行此脚本，您可以在几分钟内完成以下任务：

1. **使用 Raspberry Pi Imager 工具安装 Ubuntu 22 系统**：自动化处理系统更新和所需软件包的安装。
  
2. **安装 OpenVPN 服务器**：安装 OpenVPN 并配置服务器端，生成必要的证书和密钥。

3. **生成 OpenVPN 客户端配置文件**：创建并解释客户端配置文件，确保远程连接到 OpenVPN 的客户端可以访问 Raspberry Pi 网络内的所有设备，并通过 Raspberry Pi 网络传输流量。客户端配置文件中包含所需的证书，并且客户端需要通过用户名和密码登录。

4. **部署 FRPC 客户端**：下载并配置 FRPC 客户端以连接到远端的 FRPS 服务器，并设置安全的端口映射。

5. **服务状态显示**：在启用服务后，显示 OpenVPN 和 FRPC 的当前状态，便于确认服务运行是否正常。

6. **生成 OpenVPN 客户端配置文件下载链接**：完成所有配置后，自动将客户端配置文件保存到桌面，便于下载和使用。

### 如何使用此脚本

1. 在 Raspberry Pi 上打开终端。

2. 运行以下命令下载并运行脚本：

   ```bash
   sudo apt-get update && sudo apt-get install -y curl
   curl -O https://raw.githubusercontent.com/freeman-x/Quick_setup_openvpn-frpc/main/setup_openvpn_frpc.sh
   chmod +x setup_openvpn_frpc.sh
   sudo ./setup_openvpn_frpc.sh


3. 脚本将自动完成所有步骤，包括安装所需软件包、配置 OpenVPN 服务器和 FRPC 客户端、生成客户端配置文件以及设置开机自启动。

4. 脚本执行完毕后，您将在桌面上找到 `*.ovpn` 文件，您可以将其下载到您的计算机上并使用它连接到 OpenVPN 服务器。

### 注意事项

- 确保您的网络配置允许必要的端口通过。

---

这份脚本及其介绍将帮助您轻松部署和配置 OpenVPN 服务器和 FRPC 客户端，为您的 Raspberry Pi 提供安全的远程访问能力。
