#!/bin/bash

# 检查是否为root下运行
[[ $EUID -ne 0 ]] && echo -e '\033[1;35m请在root用户下运行脚本\033[0m' && exit 1

ARGO_DOMAIN=${1:-''}
ARGO_AUTH=${2:-''}

apt install -y jq

IP_INFO=$(curl -4 https://free.freeipapi.com/api/json)
SERVER_IP=$(echo "$IP_INFO" | jq -r .ipAddress)
COUNTRY=$(echo "$IP_INFO" | jq -r .countryCode)
VPS_ORG_FULL=$(echo "$IP_INFO" | jq -r .asnOrganization)
VPS_ORG=$(echo "$VPS_ORG_FULL" | cut -d' ' -f1)
PASSWORD=$(cat /proc/sys/kernel/random/uuid)

echo "SERVER_IP: $SERVER_IP"
echo "PASSWORD: $PASSWORD"
echo "ARGO_DOMAIN: $ARGO_DOMAIN"
echo "ARGO_AUTH: $ARGO_AUTH"
echo "[$COUNTRY] $VPS_ORG"

cat <<EOF > "config.conf"
L='C'
SERVER_IP='$SERVER_IP'
ARGO_DOMAIN='$ARGO_DOMAIN'
ARGO_AUTH='$ARGO_AUTH'
SERVER='visa.com'
UUID='$PASSWORD'
NODE_NAME='[$COUNTRY] $VPS_ORG'
EOF

# gen config
bash <(wget -qO- https://raw.githubusercontent.com/zmlu/sba/main/sba.sh?_=$(date +%s)) -f /root/config.conf