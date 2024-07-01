#!/bin/bash

# Define script version
SCRIPT_VERSION="1.0.1"

# Print script version
echo "Raspberry Pi OpenVPN and FRPC Installation Script - Version $SCRIPT_VERSION"

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then 
  echo "Please run this script as root"
  exit
fi

# Get device hostname and serial number
HOSTNAME=$(hostname)
SERIAL_NUMBER=$(awk '/Serial/ {print $3}' /proc/cpuinfo)

# Client configuration file name
CLIENT_CONF_NAME="${HOSTNAME}_${SERIAL_NUMBER}.ovpn"

# Update system and install required packages
echo "Updating system packages..."
apt update && apt upgrade -y

# Install OpenVPN and EasyRSA
echo "Installing OpenVPN and EasyRSA..."
apt install -y openvpn easy-rsa iptables-persistent

# Set up EasyRSA directory and initialize
EASYRSA_DIR=~/openvpn-ca
mkdir -p $EASYRSA_DIR
cd $EASYRSA_DIR
make-cadir .
cd $EASYRSA_DIR
./easyrsa init-pki

# Generate CA
echo "Generating CA certificate..."
./easyrsa --batch build-ca nopass

# Generate server certificate and key
echo "Generating server certificate and key..."
./easyrsa gen-req server nopass
./easyrsa --batch sign-req server server

# Generate Diffie-Hellman parameters
echo "Generating Diffie-Hellman parameters..."
./easyrsa gen-dh

# Generate client certificate and key
echo "Generating client certificate and key..."
./easyrsa gen-req client1 nopass
./easyrsa --batch sign-req client client1

# Copy certificates and keys to OpenVPN directory
echo "Copying certificates and keys to OpenVPN directory..."
cp $EASYRSA_DIR/pki/ca.crt /etc/openvpn/
cp $EASYRSA_DIR/pki/issued/server.crt /etc/openvpn/
cp $EASYRSA_DIR/pki/private/server.key /etc/openvpn/
cp $EASYRSA_DIR/pki/dh.pem /etc/openvpn/
cp $EASYRSA_DIR/pki/issued/client1.crt /etc/openvpn/
cp $EASYRSA_DIR/pki/private/client1.key /etc/openvpn/

# Create OpenVPN server configuration file
echo "Creating OpenVPN server configuration file..."
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

# Start and enable OpenVPN service
echo "Starting and enabling OpenVPN service..."
systemctl start openvpn@server
systemctl enable openvpn@server
systemctl status openvpn@server --no-pager

# Enable IP forwarding
echo "Enabling IP forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf

# Configure NAT
echo "Configuring NAT..."
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
netfilter-persistent save
netfilter-persistent reload

# Prompt user for FRPS server IP, token, and remote port
read -p "Enter the FRPS server IP: " FRPS_SERVER_IP
read -p "Enter the FRPS token: " FRPS_TOKEN
read -p "Enter the remote port for FRPC to connect: " FRPC_REMOTE_PORT

# Create client configuration file
echo "Creating OpenVPN client configuration file..."
cat > ~/$CLIENT_CONF_NAME <<EOF
client
dev tun
proto udp
remote $FRPS_SERVER_IP $FRPC_REMOTE_PORT
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

# Download and install FRPC
echo "Downloading and installing FRPC..."
wget https://github.com/fatedier/frp/releases/download/v0.37.1/frp_0.37.1_linux_arm.tar.gz -O ~/frp_0.37.1_linux_arm.tar.gz
tar -zxvf ~/frp_0.37.1_linux_arm.tar.gz -C ~/
mkdir -p ~/frp_0.37.1_linux_arm

# Configure FRPC
echo "Configuring FRPC..."
cat > ~/frp_0.37.1_linux_arm/frpc.ini <<EOF
[common]
server_addr = $FRPS_SERVER_IP
server_port = 7000
token = $FRPS_TOKEN

[openvpn]
type = tcp
local_ip = 127.0.0.1
local_port = 1194
remote_port = $FRPC_REMOTE_PORT
EOF

# Create and enable FRPC service
echo "Creating and enabling FRPC service..."
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
systemctl status frpc --no-pager

# Generate client configuration file download link
echo "Generating OpenVPN client configuration file download link..."
cp ~/$CLIENT_CONF_NAME ~/Desktop/$CLIENT_CONF_NAME
echo "Client configuration file has been generated and saved to the desktop: ~/Desktop/$CLIENT_CONF_NAME"

echo "To download the client configuration file to your local machine, use the following command:"
echo "scp $(whoami)@$(hostname -I | awk '{print $1}'):/home/$(whoami)/Desktop/$CLIENT_CONF_NAME ~/Desktop/"

echo "Installation and configuration complete. Script version: $SCRIPT_VERSION"

# Wait for user to press any key to exit
echo -n "Press any key to exit..."
read -n 1 -s
