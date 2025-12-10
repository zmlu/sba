#!/bin/bash

# Cloudflare Tunnel 管理脚本
# 用法: ./script.sh <ZONE_ID> <ACCOUNT_ID> <CLOUDFLARE_API_TOKEN> <TUNNEL_NAME> <DOMAIN_NAME> <SERVICE_URL>

set -e

# 检查参数
if [ $# -lt 5 ] || [ $# -gt 6 ]; then
    echo "用法: $0 <ZONE_ID> <ACCOUNT_ID> <CLOUDFLARE_API_TOKEN> <TUNNEL_NAME> <DOMAIN_NAME> [SERVICE_URL]"
    echo ""
    echo "参数说明:"
    echo "  SERVICE_URL: 可选，默认为 http://localhost:3010"
    echo "  示例: https://localhost:8080 或 http://192.168.1.100:3000"
    exit 1
fi

ZONE_ID="$1"
ACCOUNT_ID="$2"
CLOUDFLARE_API_TOKEN="$3"
TUNNEL_NAME="$4"
DOMAIN_NAME="$5"
SERVICE_URL="${6:-http://localhost:3010}"

API_BASE="https://api.cloudflare.com/client/v4"
AUTH_HEADER="Authorization: Bearer $CLOUDFLARE_API_TOKEN"

echo "=========================================="
echo "Cloudflare Tunnel 配置脚本"
echo "=========================================="
echo "Zone ID: $ZONE_ID"
echo "Account ID: $ACCOUNT_ID"
echo "Tunnel Name: $TUNNEL_NAME"
echo "Domain: $DOMAIN_NAME"
echo "Service URL: $SERVICE_URL"
echo "=========================================="

# 步骤 1: 查询并处理现有 Tunnel
echo ""
echo "[步骤 1] 查询现有 Tunnel..."

TUNNEL_LIST=$(curl -s -X GET \
    "${API_BASE}/accounts/${ACCOUNT_ID}/cfd_tunnel" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json")

# 检查是否存在同名 Tunnel（可能有多个）
EXISTING_TUNNEL_IDS=$(echo "$TUNNEL_LIST" | jq -r ".result[] | select(.name == \"$TUNNEL_NAME\") | .id")

if [ -n "$EXISTING_TUNNEL_IDS" ]; then
    echo "发现 $(echo "$EXISTING_TUNNEL_IDS" | wc -l) 个同名 Tunnel，正在逐一删除..."

    while IFS= read -r TUNNEL_ID_TO_DELETE; do
        if [ -n "$TUNNEL_ID_TO_DELETE" ] && [ "$TUNNEL_ID_TO_DELETE" != "null" ]; then
            echo "  正在删除 Tunnel ID: $TUNNEL_ID_TO_DELETE"

            DELETE_RESPONSE=$(curl -s -X DELETE \
                "${API_BASE}/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID_TO_DELETE}" \
                -H "$AUTH_HEADER" \
                -H "Content-Type: application/json")

            DELETE_SUCCESS=$(echo "$DELETE_RESPONSE" | jq -r '.success')
            if [ "$DELETE_SUCCESS" = "true" ]; then
                echo "  ✓ 已删除 Tunnel: $TUNNEL_ID_TO_DELETE"
            else
                echo "  ✗ 删除 Tunnel 失败: $(echo "$DELETE_RESPONSE" | jq -r '.errors')"
                # 继续删除其他 Tunnel，不退出
            fi
        fi
    done <<< "$EXISTING_TUNNEL_IDS"

    echo "✓ 所有同名 Tunnel 已处理完成"
else
    echo "未找到现有 Tunnel"
fi

# 生成 Tunnel Secret (至少 32 字节的 base64 编码)
echo ""
echo "正在生成 Tunnel Secret..."
TUNNEL_SECRET=$(openssl rand -base64 32)
echo "✓ Tunnel Secret 已生成"

# 创建新 Tunnel
echo ""
echo "正在创建新 Tunnel..."

CREATE_RESPONSE=$(curl -s -X POST \
    "${API_BASE}/accounts/${ACCOUNT_ID}/cfd_tunnel" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "{
        \"name\": \"$TUNNEL_NAME\",
        \"config_src\": \"cloudflare\",
        \"tunnel_secret\": \"$TUNNEL_SECRET\"
    }")

CREATE_SUCCESS=$(echo "$CREATE_RESPONSE" | jq -r '.success')
if [ "$CREATE_SUCCESS" != "true" ]; then
    echo "✗ 创建 Tunnel 失败: $(echo "$CREATE_RESPONSE" | jq -r '.errors')"
    exit 1
fi

TUNNEL_ID=$(echo "$CREATE_RESPONSE" | jq -r '.result.id')
TUNNEL_TOKEN=$(echo "$CREATE_RESPONSE" | jq -r '.result.token')
echo "✓ Tunnel 创建成功"
echo "  Tunnel ID: $TUNNEL_ID"

# 步骤 2: 配置 Tunnel
echo ""
echo "[步骤 2] 配置 Tunnel ingress 规则..."

CONFIG_RESPONSE=$(curl -s -X PUT \
    "${API_BASE}/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "{
        \"config\": {
            \"ingress\": [
                {
                    \"service\": \"${SERVICE_URL}\",
                    \"hostname\": \"${TUNNEL_NAME}.${DOMAIN_NAME}\",
                    \"originRequest\": {
                        \"noTLSVerify\": true
                    }
                },
                {
                    \"service\": \"http_status:404\"
                }
            ],
            \"warp-routing\": {
                \"enabled\": false
            }
        }
    }")

CONFIG_SUCCESS=$(echo "$CONFIG_RESPONSE" | jq -r '.success')
if [ "$CONFIG_SUCCESS" != "true" ]; then
    echo "✗ 配置 Tunnel 失败: $(echo "$CONFIG_RESPONSE" | jq -r '.errors')"
    exit 1
fi

echo "✓ Tunnel 配置成功"

# 步骤 3: 管理 DNS 记录
echo ""
echo "[步骤 3] 管理 DNS 记录..."

FULL_DOMAIN="${TUNNEL_NAME}.${DOMAIN_NAME}"
DNS_LIST=$(curl -s -X GET \
    "${API_BASE}/zones/${ZONE_ID}/dns_records?type=CNAME&name=${FULL_DOMAIN}" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json")

EXISTING_DNS_ID=$(echo "$DNS_LIST" | jq -r ".result[] | select(.name == \"$FULL_DOMAIN\") | .id" | head -n 1)

DNS_PAYLOAD="{
    \"name\": \"${FULL_DOMAIN}\",
    \"type\": \"CNAME\",
    \"content\": \"${TUNNEL_ID}.cfargotunnel.com\",
    \"proxied\": true,
    \"settings\": {
        \"flatten_cname\": false
    }
}"

if [ -n "$EXISTING_DNS_ID" ] && [ "$EXISTING_DNS_ID" != "null" ]; then
    echo "发现现有 DNS 记录 (ID: $EXISTING_DNS_ID)，正在更新..."

    DNS_RESPONSE=$(curl -s -X PATCH \
        "${API_BASE}/zones/${ZONE_ID}/dns_records/${EXISTING_DNS_ID}" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$DNS_PAYLOAD")

    DNS_SUCCESS=$(echo "$DNS_RESPONSE" | jq -r '.success')
    if [ "$DNS_SUCCESS" != "true" ]; then
        echo "✗ 更新 DNS 记录失败: $(echo "$DNS_RESPONSE" | jq -r '.errors')"
        exit 1
    fi

    echo "✓ DNS 记录更新成功"
else
    echo "未找到现有 DNS 记录，正在创建..."

    DNS_RESPONSE=$(curl -s -X POST \
        "${API_BASE}/zones/${ZONE_ID}/dns_records" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$DNS_PAYLOAD")

    DNS_SUCCESS=$(echo "$DNS_RESPONSE" | jq -r '.success')
    if [ "$DNS_SUCCESS" != "true" ]; then
        echo "✗ 创建 DNS 记录失败: $(echo "$DNS_RESPONSE" | jq -r '.errors')"
        exit 1
    fi

    echo "✓ DNS 记录创建成功"
fi

# 完成
echo ""
echo "=========================================="
echo "✓ 所有操作完成!"
echo "=========================================="
echo "Tunnel ID: $TUNNEL_ID"
echo "Tunnel 域名: ${FULL_DOMAIN}"
echo "Tunnel Target: ${TUNNEL_ID}.cfargotunnel.com"
echo "Service: $SERVICE_URL"
echo "=========================================="
echo "Tunnel Token: $TUNNEL_TOKEN"
echo "Tunnel Json: {\"AccountTag\":\"$ACCOUNT_ID\",\"TunnelSecret\":\"$TUNNEL_SECRET\",\"TunnelID\":\"$TUNNEL_ID\",\"Endpoint\":\"\"}"
echo "=========================================="