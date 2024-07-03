#!/bin/bash

# Version: 1.0.0
# Script to install and configure CUPS with a new user for printer management.

# Function to generate a random password
generate_password() {
    echo $(< /dev/urandom tr -dc A-Za-z0-9 | head -c8)
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if CUPS is installed
if command_exists dpkg && dpkg -l | grep -q cups; then
    echo "CUPS is already installed, resetting configuration..."
    sudo systemctl stop cups
    sudo rm -rf /etc/cups
    sudo rm -rf /var/spool/cups
    sudo apt-get remove --purge -y cups
    sudo apt-get autoremove -y
    sudo apt-get autoclean -y
elif command_exists rpm && rpm -q cups; then
    echo "CUPS is already installed, resetting configuration..."
    sudo systemctl stop cups
    sudo rm -rf /etc/cups
    sudo rm -rf /var/spool/cups
    sudo yum remove -y cups
    sudo yum autoremove -y
    sudo yum clean all
fi

echo "Installing CUPS..."
if command_exists apt-get; then
    sudo apt-get update
    sudo apt-get install -y cups
elif command_exists yum; then
    sudo yum install -y cups
fi

# Ensure CUPS is installed
if ! command_exists cupsctl; then
    echo "CUPS installation failed, please check your network connection and repository configuration."
    exit 1
fi

# Create cupsadmin user and generate a random password
CUPSADMIN_USER="cupsadmin"
CUPSADMIN_PASS=$(generate_password)

# Delete user if already exists
if id -u "$CUPSADMIN_USER" >/dev/null 2>&1; then
    sudo deluser --remove-home $CUPSADMIN_USER || sudo userdel -r $CUPSADMIN_USER
fi

# Create new user and set password
sudo useradd -m -s /bin/bash $CUPSADMIN_USER
echo "$CUPSADMIN_USER:$CUPSADMIN_PASS" | sudo chpasswd

# Add new user to lpadmin group
sudo usermod -aG lpadmin $CUPSADMIN_USER

# Configure CUPS to allow remote access and modify permissions
CUPS_CONF="/etc/cups/cupsd.conf"

# Backup original configuration file
if [ ! -f ${CUPS_CONF}.bak ]; then
    sudo cp $CUPS_CONF ${CUPS_CONF}.bak
fi

# Modify configuration file to allow non-root users to manage printers
sudo sed -i 's/^Listen localhost:631/Port 631/' $CUPS_CONF

# Disable TLS encryption
sudo sed -i 's/^DefaultEncryption.*/DefaultEncryption Never/' $CUPS_CONF
sudo sed -i '/^DefaultEncryption/! s/^Listen.*/Port 631/' $CUPS_CONF

# Modify permission configuration to allow everyone to access and manage
sudo sed -i '/^<Location \/>/,/^<\/Location>/ s/^#//' $CUPS_CONF
sudo sed -i '/^<Location \/admin>/,/^<\/Location>/ s/^#//' $CUPS_CONF
sudo sed -i '/^<Location \/admin\/conf>/,/^<\/Location>/ s/^#//' $CUPS_CONF

# Allow access from all IPs
sudo sed -i '/^<Location \/>/,/^<\/Location>/ {s/Order allow,deny/Order allow,deny\nAllow all/}' $CUPS_CONF
sudo sed -i '/^<Location \/admin>/,/^<\/Location>/ {s/Order allow,deny/Order allow,deny\nAllow all/}' $CUPS_CONF
sudo sed -i '/^<Location \/admin\/conf>/,/^<\/Location>/ {s/Order allow,deny/Order allow,deny\nAllow all/}' $CUPS_CONF

# Remove authentication requirements
sudo sed -i '/<Location \/admin>/,/<\/Location>/ s/Require user @SYSTEM/Require valid-user/' $CUPS_CONF
sudo sed -i '/<Location \/admin\/conf>/,/<\/Location>/ s/Require user @SYSTEM/Require valid-user/' $CUPS_CONF

# Ensure lpadmin group has sufficient permissions
sudo chgrp -R lpadmin /etc/cups
sudo chmod -R g+w /etc/cups

# Modify /etc/cups/printers.conf permissions to ensure lpadmin group users can edit
sudo chmod 660 /etc/cups/printers.conf
sudo chown root:lpadmin /etc/cups/printers.conf

# Modify /var/log/cups permissions to ensure log files are readable and writable
sudo chmod -R g+w /var/log/cups
sudo chown -R root:lpadmin /var/log/cups

# Restart CUPS service
sudo systemctl restart cups

# Get local IP address
IP=$(hostname -I | awk '{print $1}')

# Print completion message
echo "CUPS installation and configuration complete."
echo "Please use the following link for further configuration: http://${IP}:631"
echo "The cupsadmin user has been created. Username: $CUPSADMIN_USER, Password: $CUPSADMIN_PASS"
