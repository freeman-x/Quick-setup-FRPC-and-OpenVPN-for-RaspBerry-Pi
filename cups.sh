#!/bin/bash

# 更新系统并安装 CUPS
sudo apt update
sudo apt install -y cups

# 将当前用户添加到 lpadmin 组
sudo usermod -aG lpadmin $USER

# 配置 CUPS 允许远程访问
CUPS_CONF="/etc/cups/cupsd.conf"

sudo sed -i 's/^Listen localhost:631/Port 631/' $CUPS_CONF

sudo sed -i '/^<Location \/>/,+6 s/^#//' $CUPS_CONF
sudo sed -i '/^<Location \/admin>/,+6 s/^#//' $CUPS_CONF
sudo sed -i '/^<Location \/admin\/conf>/,+7 s/^#//' $CUPS_CONF

# 重启 CUPS 服务
sudo systemctl restart cups

# 打印完成信息
echo "CUPS 安装与配置完成。请在浏览器中访问 http://<你的RaspberryPi_IP>:631 进行进一步配置。"