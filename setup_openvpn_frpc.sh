#!/bin/bash

# 确保脚本以 root 身份运行
if [ "$EUID" -ne 0 ]; then 
  echo "请以 root 身份运行此脚本"
  exit
fi

# 更新系统并安装所需的软件包
echo "更新系统软件包..."
apt update && apt upgrade -y

# 安装 OpenVPN 和 EasyRSA
echo "安装 OpenVPN 和 EasyRSA..."
apt install -y openvpn easy-rsa iptables-persistent

# 设置 EasyRSA 目录并初始化
EASYRSA_DIR=~/openvpn-ca
mkdir -p $EASYRSA_DIR
cd $EASYRSA_DIR
make-cadir .
cd $EASYRSA_DIR
./easyrsa init-pki

# 生成 CA
echo "生成 CA 证书..."
./easyrsa --batch build-ca nopass

# 生成服务器证书和密钥
echo "生成服务器证书和密钥..."
./easyrsa gen-req server nopass
./easyrsa --batch sign-req server server

# 生成 Diffie-Hellman 参数
echo "生成 Diffie-Hellman 参数..."
./easyrsa gen-dh

# 生成客户端证书和密钥
echo "生成客户端证书和密钥..."
./easyrsa gen-req client1 nopass
./easyrsa --batch sign-req client client1

# 复制证书和密钥到 OpenVPN 目录
echo "复制证书和密钥到 OpenVPN 目录..."
cp $EASYRSA_DIR/pki/ca.crt /etc/openvpn/
cp $EASYRSA_DIR/pki/issued/server.crt /etc/openvpn/
cp $EASYRSA_DIR/pki/private/server.key /etc/openvpn/
cp $EASYRSA_DIR/pki/dh.pem /etc/openvpn/
cp $EASYRSA_DIR/pki/issued/client1.crt /etc/openvpn/
cp $EASYRSA_DIR/pki/private/client1.key /etc/openvpn/

# 创建 OpenVPN 服务器配置文件
echo "创建 OpenVPN 服务器配置文件..."
cat > /etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
keepalive 10 120
cipher AES-256-CBC
user nobody
group nogroup
persist-key
persist-tun
status openvpn-status.log
log-append /var/log/openvpn.log
verb 3
EOF

# 启动并启用 OpenVPN 服务
echo "启动并启用 OpenVPN 服务..."
systemctl start openvpn@server
systemctl enable openvpn@server
systemctl status openvpn@server

# 启用 IP 转发
echo "启用 IP 转发..."
echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf

# 配置 NAT
echo "配置 NAT..."
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
netfilter-persistent save
netfilter-persistent reload

# 创建客户端配置文件
echo "创建 OpenVPN 客户端配置文件..."
cat > ~/client1.ovpn <<EOF
client
dev tun
proto udp
remote <FRPS-服务器-IP> 6000
resolv-retry infinite
nobind
persist-key
persist-tun
ca [inline]
cert [inline]
key [inline]
remote-cert-tls server
auth-user-pass
cipher AES-256-CBC
comp-lzo
verb 3
redirect-gateway def1
dhcp-option DNS 8.8.8.8
dhcp-option DNS 8.8.4.4

<ca>
$(cat /etc/openvpn/ca.crt)
</ca>

<cert>
$(cat /etc/openvpn/client1.crt)
</cert>

<key>
$(cat /etc/openvpn/client1.key)
</key>
EOF

# 下载和安装 FRPC
echo "下载并安装 FRPC..."
wget https://github.com/fatedier/frp/releases/download/v0.37.1/frp_0.37.1_linux_arm.tar.gz -O ~/frp_0.37.1_linux_arm.tar.gz
tar -zxvf ~/frp_0.37.1_linux_arm.tar.gz -C ~/
mkdir -p ~/frp_0.37.1_linux_arm

# 配置 FRPC
echo "配置 FRPC..."
cat > ~/frp_0.37.1_linux_arm/frpc.ini <<EOF
[common]
server_addr = <FRPS-服务器-IP>
server_port = 7000
token = <FRPS-服务器-验证密码>

[openvpn]
type = tcp
local_ip = 127.0.0.1
local_port = 1194
remote_port = 6000
EOF

# 创建并启用 FRPC 服务
echo "创建并启用 FRPC 服务..."
cat > /etc/systemd/system/frpc.service <<EOF
[Unit]
Description=FRPC Client
After=network.target

[Service]
ExecStart=/home/ubuntu/frp_0.37.1_linux_arm/frpc -c /home/ubuntu/frp_0.37.1_linux_arm/frpc.ini
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl enable frpc
systemctl start frpc
systemctl status frpc

# 生成客户端配置文件下载链接
echo "生成 OpenVPN 客户端配置文件下载链接..."
cp ~/client1.ovpn ~/Desktop/client1.ovpn
echo "客户端配置文件已生成并保存到桌面：~/Desktop/client1.ovpn"

echo "所有步骤已完成！"
