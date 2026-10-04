# 用 NanoPi R2S 实现苏州大学校园网自动登录

## 背景

苏大的校园网有个很烦人的机制：包月用户每个自然月需要重新登录一次网关认证。平时用电脑浏览器登一下也就算了，但宿舍里有一堆设备——手机、平板、Switch、各种 IoT——每个月都得挨个重新连一遍，不胜其烦。

更麻烦的是，宿舍网口接了一台路由器，所有设备走 NAT 共享一个校园网 IP。理论上只要这个 IP 通过了网关认证，下面所有设备都能上网，但问题是：**谁来帮这个 IP 自动登录？**

我的选择是一台常通电的小服务器。

## 硬件与拓扑

```
宿舍网口 → 中兴巡天 AX3000 路由器(WAN口获校园网IP) ─┬→ NanoPi R2S (Armbian, 跑自动登录脚本)
                                                 ├→ 手机 / 电脑 / Switch
                                                 └→ 其他设备
```

- **NanoPi R2S**：瑞芯微 RK3328，双千兆网口，512M 内存，刷了 Armbian，功耗不到 3W，7×24 小时开机毫无压力。
- **中兴 AX3000**：负责 NAT 和 Wi-Fi，所有设备共享路由器 WAN 口的校园网 IP。
- 核心原理：苏大网关（深澜 eportal，`10.9.1.3`）按 IP 认证，NAT 后所有设备共享同一个 IP，所以只需登录一次。

## 现成的脚本，和它的坑

GitHub 上有个 [suda-gateway-login](https://github.com/Snowflyt/suda-gateway-login) 项目，提供了 Bash / PowerShell 脚本，通过调用网关 API 直接登录：

```
http://10.9.1.3:801/eportal/?c=Portal&a=login&login_method=1&user_account=,0,学号@cucc&user_password=密码&wlan_user_ip=IP
```

联通用户加 `@cucc` 后缀，移动 `@zgyd`，电信 `@ctc`。

但这个脚本有个致命问题：**它用 `hostname -I` 取本机第一个 IP 作为 `wlan_user_ip`**。对于直接连校园网的电脑没问题，但 NanoPi 在路由器 LAN 侧，拿到的是 `192.168.5.x`——一个私网地址，网关不认。

## 踩坑实录

### 坑一：WAN IP 探测全面失败

一开始我给脚本加了五级自动探测：门户跳转 URL、任意 http 站点跳转、门户页面 HTML、`get_online_info` 接口、兜底 `hostname -I`。结果：

- 门户跳转到 `?m=main&a=login`，**不带 `wlan_user_ip` 参数**
- 访问百度不跳转（门户直接返回 200 替换内容）
- 门户页面 HTML 里**完全没有客户端 IP**
- `get_online_info` 接口返回空

这个门户是广州热点的 EPORTAL 3.0，网页表单靠请求来源 IP 自动识别，不把 IP 嵌进页面。而无验证码的 API 接口又强制要求 `wlan_user_ip`——不带就返回 `"获取用户IP失败，请重试！"`,我真tm服了的。

### 坑二：UPnP 没开

既然门户不告诉我们 IP，那就问路由器要。NanoPi 装了 `miniupnpc` 想通过 UPnP 查路由器外网 IP：

```
No IGD UPnP Device found on the network !
```

中兴这台路由器把 UPnP 关了，此路不通。

### 坑三：最终从路由器管理页挖到 IP

中兴路由器的「网络 → WAN」页面也不直接显示 WAN IP。最后在「系统 → 关于系统」页面的 WAN 状态里找到了：

```
IP 地址:    10.90.0.2xx
子网掩码:   255.255.128.0
默认网关:   10.90.0.1
IPv4在线时长: 19天11小时
```

19 天没换过 IP，说明校园网 DHCP 分配的地址非常稳定。手动填进配置文件，登录立刻成功。

ps: 其实这里傻逼了，大家只需要跑一下网关登录就能拿到 `wlan_user_ip`

### 坑四：systemd 定时器不触发

脚本手动跑没问题，但配 systemd timer 后，日志里只有开机那一次记录，之后再也不触发。查了才发现：

```ini
[Service]
Type=oneshot
RemainAfterExit=yes    # ← 罪魁祸首
```

`RemainAfterExit=yes` 导致 oneshot 服务跑完后一直停在 `active` 状态，定时器触发发现服务已 active，跳过。**去掉这一行，定时器就ok了。**

另外定时器建议用 `OnCalendar` 而不是 `OnUnitActiveSec`，对 oneshot 服务更可靠：

```ini
[Timer]
OnBootSec=30s
OnCalendar=*:0/5    # 每5分钟
AccuracySec=10s
Persistent=true
```

## 最终方案

### 脚本核心逻辑

```bash
# 1. 检测是否已在线（generate_204 端点，被门户拦截时不返回204）
# 2. 已在线则跳过；未在线则用配置中的 WAN_IP 登录
# 3. 登录后验证联网，失败重试3次
```

### 配置文件 `/opt/suda_gateway/config`

```bash
USERNAME="学号@cucc"
PASSWORD="网关密码"
WAN_IP="10.90.0.xxx"   # 从路由器管理页获取
```

### systemd 定时

- 开机 30 秒后执行一次
- 之后每 5 分钟执行一次
- 已在线直接跳过

### 效果

- 每月月初认证过期 → 5 分钟内自动重登
- 被网关踢下线 → 5 分钟内自动重登
- 路由器下所有设备完全无感，不需要任何操作
- 日志：`journalctl -u suda-gateway.service -f`

## 部署步骤

```bash
# 1. 传文件到 NanoPi（Windows PowerShell）
scp -r nanopi-r2s root@192.168.x.x:/tmp/

# 2. 安装
ssh root@nanopi-r2s
cd /tmp/nanopi-r2s
bash install.sh

# 3. 填账号和 WAN IP
nano /opt/suda_gateway/config

# 4. 测试
bash /opt/suda_gateway/suda_gateway_login.sh

# 5. 确认定时器
systemctl status suda-gateway.timer
```

## 总结

这次折腾的核心收获：

1. **NAT 共享 IP 是校园网多设备免登录的关键**——只要一个 IP 通过认证，下面所有设备都能用。
2. **广州热点 EPORTAL 3.0 不回显客户端 IP**，自动探测 WAN IP 的路被堵死，最终靠路由器管理页手动获取。好在校园网 DHCP IP 极其稳定，手动填一次基本一劳永逸。
3. **systemd oneshot 服务不要加 `RemainAfterExit=yes`**，否则定时器不会重复触发。


脚本和配置文件都放在本仓库的 `nanopi-r2s/` 目录下，苏大的同学可以直接拿去用。
