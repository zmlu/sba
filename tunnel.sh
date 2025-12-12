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

# 验证 32位 Hex 字符串 (Zone ID, Account ID)
validate_hex32() {
    if [[ ! "$1" =~ ^[a-f0-9]{32}$ ]]; then
        echo "✗ 错误: ID 格式校验失败 ($1)，应为 32 位 Hex 字符串。"
        exit 1
    fi
}

# 验证 UUID (Tunnel ID)
validate_uuid() {
    if [[ ! "$1" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
        echo "✗ 错误: Tunnel ID 格式校验失败 ($1)，应为 UUID 格式。"
        exit 1
    fi
}

# JSON 提取 用法: echo "$JSON" | get_json_value "key"
get_json_value() {
    local key=$1
    # 1. grep -o 匹配 "key": 后面的内容，直到遇到逗号或右大括号 (不假设值有引号)
    # 2. head -n 1 取第一个匹配项
    # 3. cut 取冒号后的值部分
    # 4. sed 去除可能存在的首尾空白和双引号 (支持 "value", true, 123 等)
    grep -o "\"$key\":[^,}]*" | head -n 1 | cut -d':' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//'
}

# 参数检查与初始化
if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "用法: $0 <CLOUDFLARE_API_TOKEN> <DOMAIN_NAME> [SERVICE_URL]"
    echo ""
    echo "参数说明:"
    echo "  CLOUDFLARE_API_TOKEN: Cloudflare API Token"
    echo "  DOMAIN_NAME: 完整域名，例如 app.example.com（必须包含子域名）"
    echo "  SERVICE_URL: 可选，默认为 http://localhost:3010"
    echo ""
    echo "示例:"
    echo "  $0 your_token app.example.com"
    echo "  $0 your_token app.example.com https://localhost:8443"
    exit 1
fi

CLOUDFLARE_API_TOKEN="$1"
DOMAIN_NAME="$2"
SERVICE_URL="${3:-http://localhost:3010}"

# 检查必要依赖
for cmd in wget openssl grep sed awk; do
    if ! command -v $cmd &> /dev/null; then
        echo "✗ 错误: 未找到命令 '$cmd'，请先安装。"
        exit 1
    fi
done

# 提取域名信息
DOT_COUNT=$(echo "$DOMAIN_NAME" | grep -o "\." | wc -l)
if [ "$DOT_COUNT" -lt 2 ]; then
    echo "✗ 错误: DOMAIN_NAME ($DOMAIN_NAME) 必须包含子域名 (例如: app.example.com)"
    exit 1
fi

TUNNEL_NAME=$(echo "$DOMAIN_NAME" | cut -d'.' -f1)
ROOT_DOMAIN=$(echo "$DOMAIN_NAME" | cut -d'.' -f2-)

API_BASE="https://api.cloudflare.com/client/v4"
# wget header
WGET_ARGS=(--no-check-certificate -qO- --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" --header "Content-Type: application/json")

echo "=========================================="
echo "Cloudflare Tunnel 配置脚本"
echo "=========================================="
echo "输入域名: $DOMAIN_NAME"
echo "=========================================="
echo "推导出Tunnel名称: $TUNNEL_NAME"
echo "推导出根域名: $ROOT_DOMAIN"
echo "Service URL: $SERVICE_URL"
echo "=========================================="

# 步骤 1: 获取 Zone ID 和 Account ID
echo ""
echo "[步骤 1] 获取 Zone ID 和 Account ID..."

ZONE_RESPONSE=$(wget "${WGET_ARGS[@]}" "${API_BASE}/zones?name=${ROOT_DOMAIN}")

# 提取 Zone ID
ZONE_ID=$(echo "$ZONE_RESPONSE" | grep -o '"id":"[a-f0-9]\{32\}"' | head -n 1 | cut -d'"' -f4)

# 提取 Account ID
ACCOUNT_ID=$(echo "$ZONE_RESPONSE" | sed -n 's/.*"account":{"id":"\([a-f0-9]\{32\}\)".*/\1/p' | head -n 1)

if [ -z "$ZONE_ID" ]; then
    echo "✗ 无法获取 Zone ID，请检查域名是否正确或 Token 权限 (Zone:Read)。"
    exit 1
fi

if [ -z "$ACCOUNT_ID" ]; then
    echo "✗ 无法获取 Account ID，请检查 Token 权限。"
    exit 1
fi

validate_hex32 "$ZONE_ID"
validate_hex32 "$ACCOUNT_ID"

echo "✓ Zone ID: $ZONE_ID"
echo "✓ Account ID: $ACCOUNT_ID"

# 步骤 2: 查询并处理现有 Tunnel
echo ""
echo "[步骤 2] 检查现有 Tunnel..."

# 查询未删除的同名隧道
TUNNEL_LIST=$(wget "${WGET_ARGS[@]}" "${API_BASE}/accounts/${ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false")

# 尝试提取现有 ID
EXISTING_TUNNEL_ID=$(echo "$TUNNEL_LIST" | grep -o '"id":"[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}"' | head -n 1 | cut -d'"' -f4)

TUNNEL_ID=""
TUNNEL_TOKEN=""
TUNNEL_SECRET=""

if [ -n "$EXISTING_TUNNEL_ID" ]; then
    validate_uuid "$EXISTING_TUNNEL_ID"
    echo "✓ 发现现有隧道，准备复用。"
    TUNNEL_ID="$EXISTING_TUNNEL_ID"
    echo "✓ Tunnel ID: $TUNNEL_ID"

    # 获取 Tunnel Token (复用时需要单独获取 Token)
    TOKEN_RESPONSE=$(wget "${WGET_ARGS[@]}" "${API_BASE}/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token")
    TUNNEL_TOKEN=$(echo "$TOKEN_RESPONSE" | get_json_value "result")

    if [ -z "$TUNNEL_TOKEN" ]; then
         echo "✗ 错误: 无法获取 Tunnel Token"
         exit 1
    fi

    echo "✓ Tunnel Token: $TUNNEL_TOKEN"

    # 从 Token 中解析 Secret (base64 decode) Token 结构: {"a":"account_tag","t":"tunnel_id","s":"tunnel_secret"}
    # 优先使用 base64 命令，如果不存在则尝试 openssl
    if command -v base64 &> /dev/null; then
        TOKEN_DECODED=$(echo "$TUNNEL_TOKEN" | base64 -d 2>/dev/null)
    else
        TOKEN_DECODED=$(echo "$TUNNEL_TOKEN" | openssl enc -d -base64 -A 2>/dev/null)
    fi

    # 提取 "s" (TunnelSecret)
    TUNNEL_SECRET=$(echo "$TOKEN_DECODED" | get_json_value "s")

    if [ -n "$TUNNEL_SECRET" ]; then
        echo "✓ Tunnel Secret: $TUNNEL_SECRET"
    fi

else
    echo "未发现现有活跃隧道，正在创建新隧道..."

    # 生成 32 字节随机 Secret 并 Base64 编码
    TUNNEL_SECRET=$(openssl rand -base64 32)
    CREATE_PAYLOAD="{\"name\":\"$TUNNEL_NAME\",\"config_src\":\"cloudflare\",\"tunnel_secret\":\"$TUNNEL_SECRET\"}"
    CREATE_RESPONSE=$(wget "${WGET_ARGS[@]}" --method=POST --body-data="$CREATE_PAYLOAD" "${API_BASE}/accounts/${ACCOUNT_ID}/cfd_tunnel")
    IS_SUCCESS=$(echo "$CREATE_RESPONSE" | get_json_value "success")
    if [ "$IS_SUCCESS" != "true" ]; then
        echo "✗ 创建 Tunnel 失败。"
        echo "响应: $CREATE_RESPONSE"
        exit 1
    fi

    TUNNEL_ID=$(echo "$CREATE_RESPONSE" | get_json_value "id")
    TUNNEL_TOKEN=$(echo "$CREATE_RESPONSE" | get_json_value "token")

    validate_uuid "$TUNNEL_ID"
    echo "✓ 新隧道创建成功。"
    echo "✓ Tunnel ID: $TUNNEL_ID"
    echo "✓ Tunnel Token: $TUNNEL_TOKEN"
    echo "✓ Tunnel Secret: $TUNNEL_SECRET"
fi

# ==========================================
# 步骤 3: 配置 Tunnel (Ingress Rules)
# ==========================================
echo ""
echo "[步骤 3] 配置 Tunnel ingress 规则..."

# 检查是否需要 HTTPS 配置
TLS_CONFIG=""
if [[ "$SERVICE_URL" == https* ]]; then
    echo "  检测到 HTTPS 服务，添加 noTLSVerify 配置..."
    TLS_CONFIG=',"originRequest":{"noTLSVerify":true}'
fi

# 手动构造复杂的 JSON 配置文件
# 注意：Shell 变量拼接 JSON 需要非常小心引号
CONFIG_PAYLOAD="{
    \"config\": {
        \"ingress\": [
            {
                \"service\": \"$SERVICE_URL\",
                \"hostname\": \"$DOMAIN_NAME\"${TLS_CONFIG}
            },
            {
                \"service\": \"http_status:404\"
            }
        ],
        \"warp-routing\": {
            \"enabled\": false
        }
    }
}"

CONFIG_RESPONSE=$(wget "${WGET_ARGS[@]}" --method=PUT --body-data="$CONFIG_PAYLOAD" "${API_BASE}/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations")

CONFIG_SUCCESS=$(echo "$CONFIG_RESPONSE" | get_json_value "success")

if [ "$CONFIG_SUCCESS" != "true" ]; then
    echo "✗ 配置 Tunnel 失败。"
    echo "响应: $CONFIG_RESPONSE"
    exit 1
fi

echo "✓ Tunnel 配置已更新: $SERVICE_URL -> $DOMAIN_NAME"

# ==========================================
# 步骤 4: 管理 DNS 记录
# ==========================================
echo ""
echo "[步骤 4] 管理 DNS 记录..."

# 查询现有 DNS 记录
DNS_LIST=$(wget "${WGET_ARGS[@]}" "${API_BASE}/zones/${ZONE_ID}/dns_records?type=CNAME&name=${DOMAIN_NAME}")

EXISTING_DNS_ID=$(echo "$DNS_LIST" | grep -o '"id":"[a-f0-9]\{32\}"' | head -n 1 | cut -d'"' -f4)

CNAME_TARGET="${TUNNEL_ID}.cfargotunnel.com"
DNS_PAYLOAD="{\"name\":\"${DOMAIN_NAME}\",\"type\":\"CNAME\",\"content\":\"${CNAME_TARGET}\",\"proxied\":true,\"settings\":{\"flatten_cname\":false}}"

if [ -n "$EXISTING_DNS_ID" ]; then
    validate_hex32 "$EXISTING_DNS_ID"
    echo "发现现有 DNS 记录 (ID: $EXISTING_DNS_ID)，正在更新..."

    DNS_RESPONSE=$(wget "${WGET_ARGS[@]}" --method=PATCH --body-data="$DNS_PAYLOAD" "${API_BASE}/zones/${ZONE_ID}/dns_records/${EXISTING_DNS_ID}")
else
    echo "未找到现有 DNS 记录，正在创建..."

    DNS_RESPONSE=$(wget "${WGET_ARGS[@]}" --method=POST --body-data="$DNS_PAYLOAD" "${API_BASE}/zones/${ZONE_ID}/dns_records")
fi

DNS_SUCCESS=$(echo "$DNS_RESPONSE" | get_json_value "success")

if [ "$DNS_SUCCESS" != "true" ]; then
    echo "✗ 创建 DNS 记录失败: $DNS_RESPONSE"
    exit 1
fi

echo "✓ DNS 记录创建成功"

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