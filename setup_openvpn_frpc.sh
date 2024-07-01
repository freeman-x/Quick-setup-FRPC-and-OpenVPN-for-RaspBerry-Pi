#!/bin/bash

# Define script version
SCRIPT_VERSION="1.0.3"

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
CERT_INFO_FILE=~/openvpn_cert_info.txt

# Define directories and files
EASYRSA_DIR=~/openvpn-ca
FRPC_DIR=~/frp_0.37.1_linux_arm
CLIENT_OVPN_FILE=~/$CLIENT_CONF_NAME
EASYRSA_FILES="$EASYRSA_DIR/pki/ca.crt /etc/openvpn/server.crt /etc/openvpn/server.key /etc/openvpn/dh.pem /etc/openvpn/client1.crt /etc/openvpn/client1.key"

# Generate random passphrase and Common Name
generate_passphrase() {
  openssl rand -base64 32
}

generate_common_name() {
  RANDOM_SUFFIX=$(openssl rand -hex 4)
  echo "${HOSTNAME}_${RANDOM_SUFFIX}"
}

# Function to clear existing OpenVPN, EasyRSA, and FRPC configurations
clear_all() {
  echo "Clearing all existing OpenVPN, EasyRSA, and FRPC configurations..."
  systemctl stop openvpn@server
  systemctl disable openvpn@server
  systemctl stop frpc
  systemctl disable frpc
  rm -rf $EASYRSA_DIR /etc/openvpn/* $FRPC_DIR /etc/systemd/system/frpc.service $CLIENT_OVPN_FILE
  echo "Cleared all configurations."
}

# Function to check and prompt for existing services
check_existing_services() {
  if [ -d "$EASYRSA_DIR" ] || [ -d "$FRPC_DIR" ] || [ -f "/etc/openvpn/server.conf" ]; then
    echo "Existing configurations detected."
    echo "1) Clear all existing configurations and reinstall"
    echo "2) Update existing configurations"
    read -p "Select an option (1/2): " USER_CHOICE

    case $USER_CHOICE in
      1)
        clear_all
        ;;
      2)
        echo "Updating existing configurations..."
        ;;
      *)
        echo "Invalid option. Exiting."
        exit 1
        ;;
    esac
  fi
}

# Update system and install required packages
echo "Updating system packages..."
apt update -qq > /dev/null && apt upgrade -y -qq > /dev/null
echo "System update complete."

# Check and prompt for existing services
check_existing_services

# Install OpenVPN and EasyRSA
echo "Installing OpenVPN and EasyRSA..."
apt install -y openvpn easy-rsa iptables-persistent -qq
echo "Installation complete."

# Set up EasyRSA directory and initialize
mkdir -p $EASYRSA_DIR
make-cadir $EASYRSA_DIR > /dev/null
$EASYRSA_DIR/easyrsa init-pki > /dev/null

# Generate CA
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

# Check if the certificates were generated successfully
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

# Prompt user for FRPS server IP, token, and remote port with default value 6000
read -p "Enter the FRPS server IP: " FRPS_SERVER_IP
read -p "Enter the FRPS token: " FRPS_TOKEN
read -p "Enter the remote port for FRPC to connect (default is 6000): " FRPC_REMOTE_PORT
FRPC_REMOTE_PORT=${FRPC_REMOTE_PORT:-6000}

# Create client configuration file
echo "Creating OpenVPN client configuration file..."
cat > $CLIENT_OVPN_FILE <<EOF
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
mkdir -p $FRPC_DIR

# Configure FRPC
echo "Configuring FRPC..."
cat > $FRPC_DIR/frpc.ini <<EOF
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
ExecStart=$FRPC_DIR/frpc -c $FRPC_DIR/frpc.ini
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl enable frpc
systemctl start frpc
systemctl status frpc --no-pager

# Display the path to the client configuration file
echo "The OpenVPN client configuration file has been generated and saved at: $CLIENT_OVPN_FILE"

# Finish script
read -p "Press any key to exit..." -n 1 -s
