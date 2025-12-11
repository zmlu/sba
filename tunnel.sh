#!/bin/bash

# Cloudflare Tunnel 管理脚本
# 用法: ./tunnel.sh <CLOUDFLARE_API_TOKEN> <DOMAIN_NAME> [SERVICE_URL]
#
# API Token 最小权限要求:
# 1. Account - Cloudflare Tunnel:Edit
# 2. Zone - DNS:Edit
# 3. Zone - Zone:Read
#
# 创建 API Token 步骤:
# 1. 访问 https://dash.cloudflare.com/profile/api-tokens
# 2. 点击 "Create Token"
# 3. 选择 "Create Custom Token"
# 4. 添加以下权限:
#    - Account > Cloudflare Tunnel > Edit
#    - Zone > DNS > Edit
#    - Zone > Zone > Read
# 5. Account Resources: Include > 所需账户
# 6. Zone Resources: Include > 特定Zone > 所需Zone
#
set -e

# 检查参数
if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "用法: $0 <CLOUDFLARE_API_TOKEN> <DOMAIN_NAME> [SERVICE_URL]"
    echo ""
    echo "参数说明:"
    echo "  CLOUDFLARE_API_TOKEN: Cloudflare API Token"
    echo "  DOMAIN_NAME: 完整域名，例如 app.example.com（必须包含子域名）"
    echo "  SERVICE_URL: 可选，默认为 https://localhost:3010"
    echo ""
    echo "示例:"
    echo "  $0 your_token app.example.com"
    echo "  $0 your_token app.example.com https://localhost:8080"
    exit 1
fi

CLOUDFLARE_API_TOKEN="$1"
DOMAIN_NAME="$2"
SERVICE_URL="${3:-https://localhost:3010}"

# 从 DOMAIN_NAME 提取 TUNNEL_NAME (前缀) 和根域名
DOT_COUNT=$(echo "$DOMAIN_NAME" | grep -o "\." | wc -l)

if [ "$DOT_COUNT" -lt 2 ]; then
    echo "✗ 错误: DOMAIN_NAME 必须包含子域名"
    exit 1
fi

TUNNEL_NAME=$(echo "$DOMAIN_NAME" | cut -d'.' -f1)
ROOT_DOMAIN=$(echo "$DOMAIN_NAME" | cut -d'.' -f2-)

API_BASE="https://api.cloudflare.com/client/v4"
AUTH_HEADER="Authorization: Bearer $CLOUDFLARE_API_TOKEN"

echo "=========================================="
echo "Cloudflare Tunnel 配置脚本"
echo "=========================================="
echo "输入域名: $DOMAIN_NAME"
echo "=========================================="
echo "推导出Tunnel名称: $TUNNEL_NAME"
echo "推导出根域名: $ROOT_DOMAIN"
echo "Service URL: $SERVICE_URL"
echo "=========================================="

# 步骤 0: 获取 Zone ID 和 Account ID
echo ""
echo "[步骤 0] 获取 Zone ID 和 Account ID..."

ZONE_RESPONSE=$(curl -s -X GET \
    "${API_BASE}/zones?name=${ROOT_DOMAIN}" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json")

ZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].id')
ACCOUNT_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].account.id')

if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "null" ]; then
    echo "✗ 无法找到域名 ${ROOT_DOMAIN} 对应的 Zone"
    echo "响应: $(echo "$ZONE_RESPONSE" | jq -r '.errors')"
    exit 1
fi

if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "null" ]; then
    echo "✗ 无法从 Zone 信息中获取 Account ID"
    echo "响应: $(echo "$ZONE_RESPONSE" | jq -r '.result[0]')"
    exit 1
fi

echo "✓ Zone ID: $ZONE_ID"
echo "✓ Account ID: $ACCOUNT_ID"

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
                    \"hostname\": \"${DOMAIN_NAME}\",
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

DNS_LIST=$(curl -s -X GET \
    "${API_BASE}/zones/${ZONE_ID}/dns_records?type=CNAME&name=${DOMAIN_NAME}" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json")

EXISTING_DNS_ID=$(echo "$DNS_LIST" | jq -r ".result[] | select(.name == \"$DOMAIN_NAME\") | .id" | head -n 1)

DNS_PAYLOAD="{
    \"name\": \"${DOMAIN_NAME}\",
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
echo "Zone ID: $ZONE_ID"
echo "Account ID: $ACCOUNT_ID"
echo "Tunnel ID: $TUNNEL_ID"
echo "Tunnel 名称: $TUNNEL_NAME"
echo "Tunnel 域名: ${DOMAIN_NAME}"
echo "Tunnel Target: ${TUNNEL_ID}.cfargotunnel.com"
echo "Service: $SERVICE_URL"
echo "=========================================="
echo "Tunnel Token: $TUNNEL_TOKEN"
echo "Tunnel Json: {\"AccountTag\":\"$ACCOUNT_ID\",\"TunnelSecret\":\"$TUNNEL_SECRET\",\"TunnelID\":\"$TUNNEL_ID\",\"Endpoint\":\"\"}"
echo "=========================================="