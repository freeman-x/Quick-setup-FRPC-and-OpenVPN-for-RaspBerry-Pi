#!/bin/bash

# 脚本版本
SCRIPT_VERSION="1.0.6"

echo "Raspberry Pi OpenVPN and FRPC Installation Script - Version $SCRIPT_VERSION"

# 确保以 root 身份运行
if [ "$EUID" -ne 0 ]; then 
  echo "Please run this script as root"
  exit
fi

# 获取当前用户的主目录
USER_HOME=$(eval echo ~${SUDO_USER})
if [ -z "$USER_HOME" ]; then
  echo "Error: Cannot determine the user's home directory."
  exit 1
fi

# 设备主机名和序列号
HOSTNAME=$(hostname)
SERIAL_NUMBER=$(awk '/Serial/ {print $3}' /proc/cpuinfo)

# 配置文件名
CLIENT_CONF_NAME="${HOSTNAME}_${SERIAL_NUMBER}.ovpn"
CERT_INFO_FILE="$USER_HOME/openvpn_cert_info.txt"

# 目录和文件定义
EASYRSA_DIR="$USER_HOME/openvpn-ca"
FRPC_DIR="$USER_HOME/frp_0.37.1_linux_arm"
CLIENT_OVPN_FILE="$USER_HOME/$CLIENT_CONF_NAME"

# 随机生成密码和通用名称
generate_passphrase() {
  openssl rand -base64 32
}

generate_common_name() {
  RANDOM_SUFFIX=$(openssl rand -hex 4)
  echo "${HOSTNAME}_${RANDOM_SUFFIX}"
}

# 清除所有现有的 OpenVPN、EasyRSA 和 FRPC 配置
echo "Clearing all existing OpenVPN, EasyRSA, and FRPC configurations..."
systemctl stop openvpn@server
systemctl disable openvpn@server
systemctl stop frpc
systemctl disable frpc
rm -rf $EASYRSA_DIR /etc/openvpn/* $FRPC_DIR /etc/systemd/system/frpc.service $CLIENT_OVPN_FILE
echo "Cleared all configurations."

# 更新系统并安装所需的软件包
echo "Updating system packages..."
apt update -qq > /dev/null && apt upgrade -y -qq > /dev/null
echo "System update complete."

# 安装 EasyRSA
echo "Installing EasyRSA..."
apt install -y easy-rsa -qq
echo "Installation complete."

# 下载 EasyRSA 源代码并安装到用户主目录
echo "Setting up EasyRSA..."
mkdir -p $EASYRSA_DIR
cp -r /usr/share/easy-rsa/* $EASYRSA_DIR

# 初始化 EasyRSA PKI
cd $EASYRSA_DIR
./easyrsa init-pki

# 检查 EasyRSA 是否存在并可执行
if [ ! -x "$EASYRSA_DIR/easyrsa" ]; then
  echo "Error: EasyRSA not found or not executable at $EASYRSA_DIR/easyrsa."
  exit 1
fi

# 生成 CA
PASS=$(generate_passphrase)
COMMON_NAME=$(generate_common_name)
echo "Common Name: $COMMON_NAME" > $CERT_INFO_FILE
echo "Passphrase: $PASS" >> $CERT_INFO_FILE

echo "Generating CA certificate..."
echo -e "$PASS\n$PASS" | $EASYRSA_DIR/easyrsa --batch build-ca nopass > /dev/null

# 生成服务器证书和密钥
echo "Generating server certificate and key..."
echo -e "$PASS\n$PASS" | $EASYRSA_DIR/easyrsa gen-req $COMMON_NAME nopass > /dev/null
echo -e "$PASS\n$PASS" | $EASYRSA_DIR/easyrsa --batch sign-req server $COMMON_NAME > /dev/null

# 生成 Diffie-Hellman 参数
echo "Generating Diffie-Hellman parameters..."
$EASYRSA_DIR/easyrsa gen-dh > /dev/null

# 生成客户端证书和密钥
echo "Generating client certificate and key..."
CLIENT_COMMON_NAME=$(generate_common_name)
echo "Client Common Name: $CLIENT_COMMON_NAME" >> $CERT_INFO_FILE
echo -e "$PASS\n$PASS" | $EASYRSA_DIR/easyrsa gen-req $CLIENT_COMMON_NAME nopass > /dev/null
echo -e "$PASS\n$PASS" | $EASYRSA_DIR/easyrsa --batch sign-req client $CLIENT_COMMON_NAME > /dev/null

# 检查证书是否生成成功
if [ ! -f "$EASYRSA_DIR/pki/issued/$CLIENT_COMMON_NAME.crt" ]; then
  echo "Error: $CLIENT_COMMON_NAME.crt not found."
  exit 1
fi
if [ ! -f "$EASYRSA_DIR/pki/private/$CLIENT_COMMON_NAME.key" ]; then
  echo "Error: $CLIENT_COMMON_NAME.key not found."
  exit 1
fi

# 将证书和密钥复制到 OpenVPN 目录
echo "Copying certificates and keys to OpenVPN directory..."
cp $EASYRSA_DIR/pki/ca.crt /etc/openvpn/
cp $EASYRSA_DIR/pki/issued/$COMMON_NAME.crt /etc/openvpn/server.crt
cp $EASYRSA_DIR/pki/private/$COMMON_NAME.key /etc/openvpn/server.key
cp $EASYRSA_DIR/pki/dh.pem /etc/openvpn/
cp $EASYRSA_DIR/pki/issued/$CLIENT_COMMON_NAME.crt /etc/openvpn/client1.crt
cp $EASYRSA_DIR/pki/private/$CLIENT_COMMON_NAME.key /etc/openvpn/client1.key

# 创建 OpenVPN 服务器配置文件
echo "Creating OpenVPN server configuration file..."
cat > /etc/openvpn/server.conf <<EOF
# OpenVPN 服务器监听的端口
port 1194
# 使用 TCP 协议
proto tcp
# 使用 TUN 设备（虚拟隧道接口）
dev tun

# CA 证书路径
ca ca.crt
# 服务器证书路径
cert server.crt
# 服务器私钥路径
key server.key
# Diffie-Hellman 参数路径
dh dh.pem

# 分配给 VPN 客户端的 IP 地址范围和子网掩码
server 10.8.0.0 255.255.255.0
# 保持客户端 IP 地址的持久化
ifconfig-pool-persist ipp.txt

# 将所有客户端流量重定向到 VPN
push "redirect-gateway def1 bypass-dhcp"

# 向客户端推送 DNS 服务器
push "dhcp-option DNS 8.8.8.8"
# 另一个 DNS 服务器
push "dhcp-option DNS 8.8.4.4"

# 启用客户端到客户端的通信
client-to-client

push "route 10.8.0.0 255.255.255.0"

# 保持连接：每 10 秒发送一个 ping，120 秒无响应即断开
keepalive 10 120
# 使用 AES-256-CBC 加密算法
cipher AES-256-CBC
# 以 nobody 用户身份运行
user nobody
# 以 nogroup 组身份运行
group nogroup
# 保持密钥和隧道，即使重新启动也保持不变
persist-key
# 保持隧道设备，即使重新启动也保持不变
persist-tun

# 日志配置
status /var/log/openvpn-status.log
log-append /var/log/openvpn.log
verb 3

EOF

# 启动并启用 OpenVPN 服务
echo "Starting and enabling OpenVPN service..."
systemctl start openvpn@server
systemctl enable openvpn@server
systemctl status openvpn@server --no-pager

# 启用 IP 转发
echo "Enabling IP forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf

# 配置 NAT
echo "Configuring NAT..."
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
netfilter-persistent save
netfilter-persistent reload

# 提示用户输入 FRPS 服务器 IP、token 和远程端口，默认为 6000
read -p "Enter the FRPS server IP: " FRPS_SERVER_IP
read -p "Enter the FRPS token: " FRPS_TOKEN
read -p "Enter the remote port for FRPC to connect (default is 6000): " FRPC_REMOTE_PORT
FRPC_REMOTE_PORT=${FRPC_REMOTE_PORT:-6000}

# 创建客户端配置文件
echo "Creating OpenVPN client configuration file..."
cat > $CLIENT_OVPN_FILE <<EOF
# 指定这是一个客户端配置文件
client
# 使用 TUN 设备
dev tun
# 使用 TCP 协议
proto tcp
# 指定远程服务器的 IP 和端口
remote $FRPS_SERVER_IP $FRPC_REMOTE_PORT
# 解析失败时无限重试
resolv-retry infinite
# 不绑定到特定的本地端口
nobind
# 保持密钥，即使重新连接也保持不变
persist-key
# 保持隧道设备，即使重新连接也保持不变
persist-tun
# 检查远程服务器的证书是否为 TLS 服务器
remote-cert-tls server
# 使用 AES-256-CBC 加密算法
cipher AES-256-CBC
# 日志详细级别（1-5），3 表示中等详细
verb 3
# 将所有流量重定向到 VPN
redirect-gateway def1
dhcp-option DNS 8.8.8.8
dhcp-option DNS 8.8.4.4

# CA 证书开始
<ca>
$(cat /etc/openvpn/ca.crt)
</ca>

# 客户端证书开始
<cert>
$(cat /etc/openvpn/client1.crt)
</cert>

# 客户端私钥开始
<key>
$(cat /etc/openvpn/client1.key)
</key>
EOF

# 定义下载 URL 和文件路径
FRPC_VERSION="0.37.1"
FRPC_DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v$FRPC_VERSION/frp_${FRPC_VERSION}_linux_arm.tar.gz"
FRPC_TAR_FILE="$USER_HOME/frp_${FRPC_VERSION}_linux_arm.tar.gz"
FRPC_DIR="$USER_HOME/frp_${FRPC_VERSION}_linux_arm"

# 下载并安装 FRPC
echo "Downloading and installing FRPC..."
wget $FRPC_DOWNLOAD_URL -O $FRPC_TAR_FILE

# 检查是否成功下载
if [ $? -ne 0 ]; then
  echo "Error: Failed to download FRPC from $FRPC_DOWNLOAD_URL"
  exit 1
fi

# 解压缩文件
tar -zxvf $FRPC_TAR_FILE -C $USER_HOME
if [ $? -ne 0 ]; then
  echo "Error: Failed to extract FRPC tar file."
  exit 1
fi

# 移动 FRPC 并设置权限
if [ -f "$FRPC_DIR/frpc" ]; then
  mv $FRPC_DIR/frpc /usr/local/bin/
  chmod +x /usr/local/bin/frpc
else
  echo "Error: FRPC binary not found after extraction."
  exit 1
fi

# 创建 FRPC 配置文件
echo "Creating FRPC configuration file..."
cat > /etc/frpc.ini <<EOF
[common]
server_addr = $FRPS_SERVER_IP
server_port = 7000
token = $FRPS_TOKEN

[OpenVPN]
type = tcp
local_ip = 127.0.0.1
local_port = 1194
remote_port = $FRPC_REMOTE_PORT
EOF

# 创建 FRPC systemd 服务文件
echo "Creating FRPC systemd service file..."
cat > /etc/systemd/system/frpc.service <<EOF
[Unit]
Description=FRPC Client Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /etc/frpc.ini
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# 启动并启用 FRPC 服务
echo "Starting and enabling FRPC service..."
systemctl daemon-reload
systemctl start frpc
systemctl enable frpc
systemctl status frpc --no-pager

# 打印客户端配置文件路径
echo "OpenVPN client configuration file created at: $CLIENT_OVPN_FILE "
echo "FRPC configuration file created at: /etc/frpc.ini"
echo "Script execution complete."

# 结束脚本
read -p "Press any key to exit..." -n 1 -s
