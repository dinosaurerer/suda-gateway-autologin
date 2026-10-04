#!/usr/bin/env bash
# =============================================================================
# 苏州大学校园网网关自动登录脚本（深澜 eportal）
# 适用：Armbian / 任意 Linux，可位于路由器 NAT 之后，也可直接接入校园网
# 联通账号：学号@cucc   移动：学号@zgyd   电信：学号@ctc
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config"
LOG_FILE="/var/log/suda_gateway.log"

# ---------- 加载配置 ----------
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    echo "[$(date '+%F %T')] ERROR: 找不到配置文件 $CONFIG_FILE" >&2
    exit 1
fi

: "${USERNAME:?配置中缺少 USERNAME}"
: "${PASSWORD:?配置中缺少 PASSWORD}"

GATEWAY="10.9.1.3"
PORTAL="http://${GATEWAY}:801/eportal/"
CURL="curl -s -m 8 --connect-timeout 4"

log() {
    local line="[$(date '+%F %T')] $*"
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
    echo "$line"
}

# ---------- 检测是否已在线（generate_204 端点，被门户拦截时不会返回 204）----------
is_online() {
    local url code
    for url in \
        'http://connect.rom.miui.com/generate_204' \
        'http://www.gstatic.com/generate_204' \
        'http://cp.cloudflare.com/generate_204'; do
        code=$($CURL -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
        [ "$code" = "204" ] && return 0
    done
    return 1
}

# ---------- 探测网关看到的 WAN IP（即校园网分配给路由器的 IP）----------
get_wan_ip() {
    local ip=""

    # 1) eportal 根路径跳转里通常带 wlan_user_ip
    ip=$($CURL -o /dev/null -w '%{redirect_url}' "${PORTAL}" 2>/dev/null \
        | grep -oE 'wlan_user_ip=[0-9.]+' | cut -d= -f2)
    [ -n "$ip" ] && { echo "$ip"; return 0; }

    # 2) 访问任意 http 站点，被门户 302 到登录页，跳转 URL 里带 wlan_user_ip
    ip=$($CURL -o /dev/null -w '%{redirect_url}' 'http://www.baidu.com' 2>/dev/null \
        | grep -oE 'wlan_user_ip=[0-9.]+' | cut -d= -f2)
    [ -n "$ip" ] && { echo "$ip"; return 0; }

    # 3) 门户页面 HTML/JS 里通常嵌入客户端 IP
    ip=$($CURL "http://${GATEWAY}:801/" 2>/dev/null \
        | grep -oE '(v4ip|v46ip|client_ip|wlan_user_ip)[^0-9]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$ip" ] && { echo "$ip"; return 0; }

    # 4) get_online_info 接口
    ip=$($CURL "${PORTAL}?c=Portal&a=get_online_info" 2>/dev/null \
        | grep -oE '"(client_ip|online_ip|v4ip)":"[0-9.]+"' \
        | grep -oE '[0-9.]+' | head -1)
    [ -n "$ip" ] && { echo "$ip"; return 0; }

    # 5) 兜底：本机第一个 IPv4（仅当 NanoPi 直接在校园网下时正确）
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "$ip"
}

# ---------- 执行登录 ----------
do_login() {
    local ip="$1"
    local resp
    # -G + --data-urlencode 自动正确编码用户名/密码/IP
    resp=$($CURL -G \
        --data-urlencode "c=Portal" \
        --data-urlencode "a=login" \
        --data-urlencode "login_method=1" \
        --data-urlencode "user_account=,0,${USERNAME}" \
        --data-urlencode "user_password=${PASSWORD}" \
        --data-urlencode "wlan_user_ip=${ip}" \
        "${PORTAL}" 2>/dev/null)

    # 去掉 JSONP 括号
    resp="${resp#(}"
    resp="${resp%)}"

    if echo "$resp" | grep -q '"result":"1"'; then
        log "登录成功 (ip=$ip)"
        return 0
    elif echo "$resp" | grep -q '"ret_code":2'; then
        log "已在线，无需重复登录 (ip=$ip)"
        return 0
    else
        log "登录失败，网关返回：$resp"
        return 1
    fi
}

# ---------- 主流程 ----------
if is_online; then
    log "网络已通，跳过登录。"
    exit 0
fi

if [ -n "${WAN_IP:-}" ]; then
    DETECTED_IP="$WAN_IP"
    log "使用配置中指定的 WAN_IP=$DETECTED_IP"
else
    DETECTED_IP=$(get_wan_ip)
fi

if [ -z "$DETECTED_IP" ]; then
    log "ERROR: 无法探测 WAN IP，请在 config 中手动设置 WAN_IP"
    exit 1
fi
log "探测到校园网 WAN IP: $DETECTED_IP"

for i in 1 2 3; do
    if do_login "$DETECTED_IP"; then
        sleep 2
        if is_online; then
            log "联网验证通过。"
            exit 0
        fi
        log "登录请求已发出但验证未通过，重试..."
    fi
    [ "$i" -lt 3 ] && sleep 3
done

log "ERROR: 多次重试后仍未联网"
exit 1
