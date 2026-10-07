#!/bin/bash
set -e

# ========== 1. Telegram 通知配置 ==========
TG_TOKEN="8526087156:AAHR5forb44MA061r0zgcPMiGtkkxHD5K6o"
TG_CHAT_ID="6303873752"

# ========== 2. SNI 伪装域名配置区 ==========
# 随机 SNI 伪装域名池（每次运行自动从列表随机抽取一个）
SNI_DOMAINS=(
    "www.microsoft.com"
    "aws.amazon.com"
    "www.apple.com"
    "gateway.icloud.com"
    "www.cloudflare.com"
    "cdn.jsdelivr.net"
    "www.lovelive-anime.jp"
)
SNI_DOMAIN=${SNI_DOMAINS[$RANDOM % ${#SNI_DOMAINS[@]}]}

# ========== 3. ⭐ JA3Proxy / TLS 访问指纹配置区（改这里）⭐ ==========
# 客户端在访问目标网站时使用的 TLS/ClientHello 浏览器指纹预设：
#   Chrome 系列 : chrome, chrome_100, chrome_106, chrome_120, chrome_124, chrome_131, chrome_133
#   Safari 系列 : safari, safari_15, safari_16, safari_17_0, safari_18_0
#   Firefox 系列: firefox, firefox_102, firefox_120, firefox_133
#   Edge 系列   : edge, edge_101, edge_106
#   随机伪装    : randomized, randomized_alpn
TLS_FINGERPRINT="chrome120"
# =============================================================

# ========== 4. 端口配置区 ==========
LISTEN_PORT=10111
# ==================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── 1. 检查 Docker 环境 ─────────────────────────
log "检查 Docker 环境..."
if ! command -v docker &>/dev/null; then
    warn "Docker 未安装，正在安装..."
    apt-get update -qq && apt-get install -y -qq docker.io
    systemctl start docker && systemctl enable docker
fi
docker info &>/dev/null || err "Docker 守护进程未运行"

# 预先拉取镜像，防止拉取日志混入后文密钥提取管道
log "预热拉取 Xray 镜像..."
docker pull ghcr.io/xtls/xray-core:latest &>/dev/null || true

# ── 2. 清理旧容器与端口占用 ──────────────────────
log "清理旧容器与端口..."
docker rm -f xray xray-reality ss-rust shadow-tls ja3proxy 2>/dev/null || true
sleep 1
fuser -k ${LISTEN_PORT}/tcp 2>/dev/null || true
sleep 1

# ── 3. 生成 REALITY 伪装密钥与 UUID ──────────────
log "配置 REALITY 密钥与伪装参数..."
UUID=$(cat /proc/sys/kernel/random/uuid)

# 修复：使用 awk 正则匹配冒号和不同格式，彻底避免生成空 privateKey
KEYS=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519 2>/dev/null)
PRIVATE_KEY=$(echo "$KEYS" | awk -F': ' '/Private/ {print $2}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$KEYS" | awk -F': ' '/Public/ {print $2}' | tr -d ' \r\n')

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    err "生成 REALITY 密钥失败，请检查 Docker 环境"
fi

SHORT_ID=$(openssl rand -hex 8)

# ── 4. 创建 Xray 配置并启动容器 ─────────────────
log "启动 Xray 服务端 (伪装域名: ${SNI_DOMAIN})..."
mkdir -p /etc/xray
cat <<EOF > /etc/xray/config.json
{
  "inbounds": [{
    "port": ${LISTEN_PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${SNI_DOMAIN}:443",
        "xver": 0,
        "serverNames": ["${SNI_DOMAIN}"],
        "privateKey": "${PRIVATE_KEY}",
        "shortIds": ["${SHORT_ID}"]
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom"
  }]
}
EOF

docker run -d \
    --name xray \
    --restart always \
    --network host \
    -v /etc/xray/config.json:/etc/xray/config.json \
    ghcr.io/xtls/xray-core:latest run -config /etc/xray/config.json

sleep 2

# ── 5. 验证容器运行状态 ─────────────────────────
log "验证容器状态..."
s=$(docker inspect -f '{{.State.Status}}' xray 2>/dev/null)
if [ "$s" != "running" ]; then
    warn "Xray 启动异常: $s"
    docker logs xray 2>&1 | tail -15
    exit 1
else
    log "Xray 运行正常"
fi

# ── 6. 获取公网 IP ──────────────────────────────
SERVER_IP=$(curl -s --max-time 10 ipv4.icanhazip.com || \
            curl -s --max-time 10 api.ipify.org)
[ -z "$SERVER_IP" ] && err "无法获取公网 IP"
log "服务器 IP: ${SERVER_IP}"

# ── 7. 生成小火箭 / Clash 节点链接 ───────────────
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_DOMAIN}&fp=${TLS_FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#TLS_${TLS_FINGERPRINT}_${SNI_DOMAIN}"

# ── 8. 推送 Telegram + 控制台汇总 ─────────────────
curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=🔗 TLS 伪装节点部署完成:
SNI 伪装域名: ${SNI_DOMAIN}
访问 TLS 指纹: ${TLS_FINGERPRINT}

节点链接:
${VLESS_LINK}" >/dev/null

echo ""
echo "══════════════════════════════════════════════"
echo "  部署完成（真实 TLS 指纹模拟版）"
echo "══════════════════════════════════════════════"
echo "  服务器 IP      : ${SERVER_IP}"
echo "  监听端口       : ${LISTEN_PORT}"
echo "  选中的 SNI 域名: ${SNI_DOMAIN}"
echo "  访问目标 TLS指纹: ${TLS_FINGERPRINT}"
echo "══════════════════════════════════════════════"
echo "  小火箭一键导入链接:"
echo "  ${VLESS_LINK}"
echo "══════════════════════════════════════════════"
docker ps --format "table {{.Names}}\t{{.Status}}"
