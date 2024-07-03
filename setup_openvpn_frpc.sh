#!/bin/bash

# Script version
SCRIPT_VERSION="1.1.3"

echo "Multi-Platform OpenVPN and FRPC Installation Script - Version $SCRIPT_VERSION"

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then 
  echo "Please run this script as root"
  exit 1
fi

# Detect system architecture
ARCH=$(uname -m)
echo "Detected system architecture: $ARCH"

# Determine package manager
if command -v apt-get > /dev/null; then
  PKG_MANAGER="apt-get"
  PKG_INSTALL="install -y"
  PKG_UPDATE="update -qq"
elif command -v yum > /dev/null; then
  PKG_MANAGER="yum"
  PKG_INSTALL="install -y"
  PKG_UPDATE="makecache fast"
elif command -v dnf > /dev/null; then
  PKG_MANAGER="dnf"
  PKG_INSTALL="install -y"
  PKG_UPDATE="makecache fast"
else
  echo "Unsupported package manager. Please install manually."
  exit 1
fi

# Get the current user's home directory
USER_HOME=$(eval echo ~${SUDO_USER})
if [ -z "$USER_HOME" ]; then
  echo "Error: Cannot determine the user's home directory."
  exit 1
fi

# Device hostname and serial number
HOSTNAME=$(hostname)
SERIAL_NUMBER=$(awk '/Serial/ {print $3}' /proc/cpuinfo 2>/dev/null || echo "N/A")

# Configuration file name
CLIENT_CONF_NAME="${HOSTNAME}_${SERIAL_NUMBER}.ovpn"
CERT_INFO_FILE="$USER_HOME/openvpn_cert_info.txt"

# Directories and files
EASYRSA_DIR="$USER_HOME/openvpn-ca"
FRPC_DIR="$USER_HOME/frp"
CLIENT_OVPN_FILE="$USER_HOME/$CLIENT_CONF_NAME"

# Function to generate a random passphrase (16 characters)
generate_passphrase() {
  head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16 ; echo ''
}

# Function to generate a common name
generate_common_name() {
  RANDOM_SUFFIX=$(openssl rand -hex 4)
  echo "${HOSTNAME}_${RANDOM_SUFFIX}"
}

# Collect FRPS server information from user
read -p "Enter the FRPS server IP: " FRPS_SERVER_IP
while [[ -z "$FRPS_SERVER_IP" ]]; do
  echo "FRPS server IP cannot be empty."
  read -p "Enter the FRPS server IP: " FRPS_SERVER_IP
done

read -p "Enter the FRPS token: " FRPS_TOKEN
while [[ -z "$FRPS_TOKEN" ]]; do
  echo "FRPS token cannot be empty."
  read -p "Enter the FRPS token: " FRPS_TOKEN
done

read -p "Enter the FRPC remote port (default is 6000): " FRPC_REMOTE_PORT
FRPC_REMOTE_PORT=${FRPC_REMOTE_PORT:-6000}

# Generate random VPN password
VPN_PASSWORD=$(generate_passphrase)
VPN_USER="openvpn"

# Clear all existing OpenVPN, EasyRSA, and FRPC configurations
echo "Clearing all existing OpenVPN, EasyRSA, and FRPC configurations..."
systemctl stop openvpn@server
systemctl disable openvpn@server
systemctl stop frpc
systemctl disable frpc
rm -rf $EASYRSA_DIR /etc/openvpn/* $FRPC_DIR /etc/systemd/system/frpc.service $CLIENT_OVPN_FILE
echo "Cleared all configurations."

# Update system and install required packages
echo "Updating system packages..."
$PKG_MANAGER $PKG_UPDATE > /dev/null
$PKG_MANAGER $PKG_INSTALL easy-rsa openvpn iptables-persistent wget tar > /dev/null
echo "System update complete."

# Install EasyRSA
echo "Setting up EasyRSA..."
mkdir -p $EASYRSA_DIR
cp -r /usr/share/easy-rsa/* $EASYRSA_DIR

# Initialize EasyRSA PKI
cd $EASYRSA_DIR
./easyrsa init-pki

# Check if EasyRSA exists and is executable
if [ ! -x "$EASYRSA_DIR/easyrsa" ]; then
  echo "Error: EasyRSA not found or not executable at $EASYRSA_DIR/easyrsa."
  exit 1
fi

# Generate CA certificate
PASS=$(generate_passphrase)
COMMON_NAME=$(generate_common_name)
echo "Common Name: $COMMON_NAME" > $CERT_INFO_FILE
echo "Passphrase: $PASS" >> $CERT_INFO_FILE

echo "Generating CA certificate..."
echo -e "$PASS\n$PASS" | $EASYRSA_DIR/easyrsa --batch build-ca nopass > /dev/null

# Generate server certificate and key
echo "Generating server certificate and key..."
echo -e "$PASS\n$PASS" | $EASYRSA_DIR/easyrsa gen-req $COMMON_NAME nopass > /dev/null
echo -e "$PASS\n$PASS" | $EASYRSA_DIR/easyrsa --batch sign-req server $COMMON_NAME > /dev/null

# Generate Diffie-Hellman parameters
echo "Generating Diffie-Hellman parameters..."
$EASYRSA_DIR/easyrsa gen-dh > /dev/null

# Generate client certificate and key
echo "Generating client certificate and key..."
CLIENT_COMMON_NAME=$(generate_common_name)
echo "Client Common Name: $CLIENT_COMMON_NAME" >> $CERT_INFO_FILE
echo -e "$PASS\n$PASS" | $EASYRSA_DIR/easyrsa gen-req $CLIENT_COMMON_NAME nopass > /dev/null
echo -e "$PASS\n$PASS" | $EASYRSA_DIR/easyrsa --batch sign-req client $CLIENT_COMMON_NAME > /dev/null

# Check if certificates are generated successfully
if [ ! -f "$EASYRSA_DIR/pki/issued/$CLIENT_COMMON_NAME.crt" ]; then
  echo "Error: $CLIENT_COMMON_NAME.crt not found."
  exit 1
fi
if [ ! -f "$EASYRSA_DIR/pki/private/$CLIENT_COMMON_NAME.key" ]; then
  echo "Error: $CLIENT_COMMON_NAME.key not found."
  exit 1
fi

# Copy certificates and keys to OpenVPN directory
echo "Copying certificates and keys to OpenVPN directory..."
cp $EASYRSA_DIR/pki/ca.crt /etc/openvpn/
cp $EASYRSA_DIR/pki/issued/$COMMON_NAME.crt /etc/openvpn/server.crt
cp $EASYRSA_DIR/pki/private/$COMMON_NAME.key /etc/openvpn/server.key
cp $EASYRSA_DIR/pki/dh.pem /etc/openvpn/
cp $EASYRSA_DIR/pki/issued/$CLIENT_COMMON_NAME.crt /etc/openvpn/client1.crt
cp $EASYRSA_DIR/pki/private/$CLIENT_COMMON_NAME.key /etc/openvpn/client1.key
echo "Certificates and keys copied."

# Create OpenVPN server configuration file
echo "Creating OpenVPN server configuration file..."
cat > /etc/openvpn/server.conf <<EOF
# Port that OpenVPN server will listen on
port 1194
# Use TCP protocol
proto tcp
# Use TUN device (virtual tunnel interface)
dev tun

# Certificate Settings
ca ca.crt
cert server.crt
key server.key
dh dh.pem

# IP address range and subnet mask to assign to VPN clients
server 10.8.0.0 255.255.255.0
# Maintain client IP address persistence
ifconfig-pool-persist ipp.txt

# Redirect all client traffic through VPN
push "redirect-gateway def1 bypass-dhcp"

# Push DNS server to clients
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"

# Enable client-to-client communication
client-to-client

push "route 10.8.0.0 255.255.255.0"

# Keep connection: ping every 10 seconds, disconnect after 120 seconds of no response
keepalive 10 120

cipher AES-256-CBC
user nobody
group nogroup
persist-key
persist-tun

# Log configuration
status /var/log/openvpn-status.log
log-append /var/log/openvpn.log
verb 3

# Add auth-user-pass-verify script
script-security 3
auth-user-pass-verify /etc/openvpn/checkpsw.sh via-env
EOF

# Create checkpsw.sh script for password verification
echo "Creating password verification script..."
cat > /etc/openvpn/checkpsw.sh <<EOF
#!/bin/bash

VPNUSER="openvpn"
VPNPASS="$VPN_PASSWORD"

if [[ "\$username" == "\$VPNUSER" && "\$password" == "\$VPNPASS" ]]; then
  exit 0
else
  exit 1
fi
EOF

# Set permissions for checkpsw.sh
chmod +x /etc/openvpn/checkpsw.sh

# Start and enable OpenVPN service
echo "Starting and enabling OpenVPN service..."
systemctl start openvpn@server
systemctl enable openvpn@server
systemctl status openvpn@server --no-pager

# Generate OpenVPN client configuration file
echo "Generating OpenVPN client configuration file..."
cat > $CLIENT_OVPN_FILE <<EOF
client
dev tun
proto tcp
remote $FRPS_SERVER_IP $FRPC_REMOTE_PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth-user-pass
cipher AES-256-CBC
verb 3

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

# Define download URL and file path for FRPC based on architecture
case "$ARCH" in
  x86_64)
    FRPC_ARCH="linux_amd64"
    ;;
  armv7l)
    FRPC_ARCH="linux_arm"
    ;;
  aarch64)
    FRPC_ARCH="linux_arm64"
    ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

FRPC_VERSION="0.37.1"
FRPC_DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v$FRPC_VERSION/frp_${FRPC_VERSION}_${FRPC_ARCH}.tar.gz"
FRPC_TAR_FILE="$USER_HOME/frp_${FRPC_VERSION}_${FRPC_ARCH}.tar.gz"
FRPC_DIR="$USER_HOME/frp_${FRPC_VERSION}_${FRPC_ARCH}"

# Download and install FRPC
echo "Downloading and installing FRPC..."
wget $FRPC_DOWNLOAD_URL -O $FRPC_TAR_FILE

# Check if download was successful
if [ $? -ne 0 ]; then
  echo "Error: Failed to download FRPC from $FRPC_DOWNLOAD_URL"
  exit 1
fi

# Extract the file
tar -zxvf $FRPC_TAR_FILE -C $USER_HOME
if [ $? -ne 0 ]; then
  echo "Error: Failed to extract FRPC tar file."
  exit 1
fi

# Move FRPC and set permissions
if [ -f "$FRPC_DIR/frpc" ]; then
  mv $FRPC_DIR/frpc /usr/local/bin/
  chmod +x /usr/local/bin/frpc
else
  echo "Error: FRPC binary not found after extraction."
  exit 1
fi

# Create FRPC configuration file
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

# Create FRPC systemd service file
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

# Start and enable FRPC service
echo "Starting and enabling FRPC service..."
systemctl daemon-reload
systemctl start frpc
systemctl enable frpc
systemctl status frpc --no-pager

# Function to start a simple HTTP server
start_http_server() {
  local port=$1
  echo "Starting a simple HTTP server on port $port..."
  python3 -m http.server $port --directory $USER_HOME > /dev/null 2>&1 &
  HTTP_SERVER_PID=$!
}

# Function to stop the HTTP server
stop_http_server() {
  if [ -n "$HTTP_SERVER_PID" ]; then
    echo "Stopping the HTTP server..."
    kill $HTTP_SERVER_PID
  fi
}

# Check if port 8000 is free
if lsof -Pi :8000 -sTCP:LISTEN -t >/dev/null ; then
  echo "Port 8000 is already in use. Please free the port and re-run the script."
  exit 1
fi

# Start HTTP server on port 8000
start_http_server 8000

# Generate download link for OpenVPN client configuration file
CLIENT_DOWNLOAD_URL="http://$(hostname -I | awk '{print $1}'):8000/$CLIENT_CONF_NAME"

# 打印生成的密码信息
echo -e "\n\033[1;32mOpenVPN 客户端连接信息：\033[0m"
echo -e "\033[1;34m用户名: \033[0mopenvpn"
echo -e "\033[1;34m密码: \033[0m$VPN_PASSWORD"

# 打印客户端配置文件路径和下载链接
echo "OpenVPN 客户端配置文件路径：$CLIENT_OVPN_FILE"
echo -e "\033[1;34m下载链接: $CLIENT_DOWNLOAD_URL\033[0m"

# 提示用户按任意键退出并停止 HTTP 服务器
read -p "按任意键退出并停止 HTTP 服务器..." -n 1 -s
stop_http_server
