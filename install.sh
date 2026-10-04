#!/usr/bin/env bash
# 一键安装：复制脚本/配置/systemd 单元，并启用定时任务
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/suda_gateway"

if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
else
    SUDO=""
fi

echo "==> 安装到 ${INSTALL_DIR}"
$SUDO mkdir -p "$INSTALL_DIR"
$SUDO cp "$SCRIPT_DIR/suda_gateway_login.sh" "$INSTALL_DIR/"
$SUDO chmod +x "$INSTALL_DIR/suda_gateway_login.sh"

if [ ! -f "$INSTALL_DIR/config" ]; then
    $SUDO cp "$SCRIPT_DIR/config.example" "$INSTALL_DIR/config"
    $SUDO chmod 600 "$INSTALL_DIR/config"
    echo "==> 已生成配置模板：$INSTALL_DIR/config"
    echo "    请务必编辑它，填入你的 学号@cucc 和网关密码！"
else
    echo "==> 配置已存在，保留原文件：$INSTALL_DIR/config"
fi

echo "==> 安装 systemd 服务与定时器"
$SUDO cp "$SCRIPT_DIR/suda-gateway.service" /etc/systemd/system/
$SUDO cp "$SCRIPT_DIR/suda-gateway.timer"  /etc/systemd/system/
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now suda-gateway.timer

echo
echo "安装完成。"
echo "  编辑配置：  nano $INSTALL_DIR/config"
echo "  手动测试：  bash $INSTALL_DIR/suda_gateway_login.sh"
echo "  查看定时器：systemctl status suda-gateway.timer"
echo "  查看日志：  journalctl -u suda-gateway.service -n 50 --no-pager"
echo "  实时日志：  journalctl -u suda-gateway.service -f"
