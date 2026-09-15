# WireGuard 4-over-6 全互联（Full Mesh）跨地域 VPC 站点对站点网关实战指南

本文档介绍如何在阿里云多地域环境下，构建 **4-over-6 混合隧道 + 跨地域 VPC 站点对站点（Site-to-Site）安全网关**。

底座传输层（Underlay）使用**公网 IPv6** 建立 WireGuard 加密通道，业务层（Overlay）承载**私网 IPv4** 跨地域互通。子网内的普通业务实例无需安装任何额外软件或客户端，即可通过透明路由网关实现毫秒级跨地域原生 IPv4 双向通信。

---

## 一、架构拓扑与参数规划

### 1. 架构全景图

```text
+---------------------------------------------------------------------------------------------------+
| 杭州 VPC (192.168.10.0/24)                                                                        |
|                                                                                                   |
|  [杭州测试机 / 业务集群] (192.168.10.x)                                                            |
|        | 发往 192.168.20.0/24 或 192.168.30.0/24 的原生 IPv4 流量                                  |
|        v                                                                                          |
|  [阿里云 VPC 路由表] 匹配目标 CIDR，下一跳自动引流至杭州网关实例 (192.168.10.251)                  |
|        |                                                                                          |
|        v                                                                                          |
|  [杭州 WireGuard 网关 ECS]                                                                        |
|     - 内核 net.ipv4.ip_forward = 1 原生路由转发                                                   |
|     - 匹配 WireGuard AllowedIPs，将 IPv4 报文加密封装为 UDP/IPv6 报文                             |
+--------|------------------------------------------------------------------------------------------+
         |
         | 公网 IPv6 传输 (Underlay): [2408:xxxx:杭州]:11111 <===> [2408:xxxx:上海]:22222
         |                          \                                /
         |                           \===> [2408:xxxx:深圳]:33333 <==/
         v
+--------|------------------------------------------------------------------------------------------+
|  [上海 WireGuard 网关 ECS] / [深圳 WireGuard 网关 ECS]                                            |
|     - 接收 UDP/IPv6 报文并解密，还原为原始内网 IPv4 报文                                          |
|     - 内核根据目标 IPv4 地址从 eth0 发往本地域 VPC 交换机                                         |
|        |                                                                                          |
|        v                                                                                          |
|  [上海测试机 / 业务集群] (192.168.20.x) 或 [深圳测试机 / 业务集群] (192.168.30.x)                  |
+---------------------------------------------------------------------------------------------------+
```

### 2. 网关节点参数对照表

| 地域 | 节点角色 | 公网 IPv6 端点 (`Endpoint`) | 监听端口 | VPC 网段 | 本地私网 IPv4 | WireGuard 隧道 IP |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **杭州** | 站点网关 | `[2408:xxxx:杭州IPv6]:11111` | `11111` | `192.168.10.0/24` | `192.168.10.251` | `10.0.0.1/8` |
| **上海** | 站点网关 | `[2408:xxxx:上海IPv6]:22222` | `22222` | `192.168.20.0/24` | `192.168.20.221` | `10.0.0.2/8` |
| **深圳** | 站点网关 | `[2408:xxxx:深圳IPv6]:33333` | `33333` | `192.168.30.0/24` | `192.168.30.56`  | `10.0.0.3/8` |

> **提示**：
> - WireGuard 中声明 IPv6 端点时，必须使用**英文中括号**包裹，格式如：`Endpoint = [2408:xxxx:xxxx::1]:11111`。
> - 子网内其他普通业务实例（测试机）无需分配 IPv6，直接使用分配的 `192.168.x.x` IPv4 地址通信。

---

## 二、网关底层准备与配置关键

### 1. 开启系统内核转发（核心唯一必需项）

作为 Site-to-Site 网关，Linux 必须允许在不同网卡之间（`eth0` 和 `wg0`）转发流量：

```bash
# 1. 开启 IPv4 转发
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard-gateway.conf

# 2. 立即生效
sysctl -p /etc/sysctl.d/99-wireguard-gateway.conf

# 3. 验证参数
sysctl net.ipv4.ip_forward
# 预期输出: net.ipv4.ip_forward = 1
```

### 2. 为什么不需要额外配置 iptables 规则？

- **安全组已接管网络策略**：在阿里云环境中，默认未启用复杂的本地防火墙，所有出入向规则均由硬件安全组集中控制。
- **内核默认策略为放通**：通过 `iptables -L FORWARD -n -v` 可以看到默认策略为 `Chain FORWARD (policy ACCEPT)`，转发报文不会被丢弃。
- **纯原生透明路由，无需 NAT**：因为阿里云 VPC 路由表中已经双向配置好了目标网段的下一跳，回包路径清晰对称，**完全无需做 MASQUERADE / SNAT**，各子网主机能直接看到对方真实的内网源 IP。

---

## 三、网关节点 WireGuard 配置（`/etc/wireguard/wg0.conf`）

> [!TIP]
> **关于 `src <本机VPC IP>` 的填写说明**：
> - 配置文件中的 `src 192.168.x.x` 请填写您在执行 `terraform apply` 后各地域网关实例实际分配到的私网 IPv4（可通过 `terraform output` 查询各地域的 `instance_private_ip`）。
> - 该参数**仅影响网关节点自身主动发起**发往对端子网的流量。
> - **子网内的测试机与业务集群发包时，天然携带各自的私网 IP 作为源地址**，由 VPC 路由表透明路由至网关并加密发往对端，无需受此限制。

### 1. 杭州网关节点配置：`/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.0.0.1/8
ListenPort = 11111
PrivateKey = 8FUTTteai08Hwe1Cq8oFgOYFWO+G7Sma5kYKNUjpa0g=

# 接口启动时指定本机 VPC IPv4 为首选源地址 (用于网关本机发起的业务流量)
PostUp = ip route replace 192.168.20.0/24 dev wg0 src 192.168.10.251
PostUp = ip route replace 192.168.30.0/24 dev wg0 src 192.168.10.251

# 对端 1：上海 (使用上海网关公网 IPv6 建立 Underlay 隧道)
[Peer]
PublicKey = YrxylafhFJblpUL+Br5KYcF+VeoJsDwlPCvxKnVDtkk=
Endpoint = [2408:4001:xxx:上海节点IPv6]:22222
AllowedIPs = 10.0.0.2/32, 192.168.20.0/24
PersistentKeepalive = 25

# 对端 2：深圳 (使用深圳网关公网 IPv6 建立 Underlay 隧道)
[Peer]
PublicKey = ZDiVSD3XyDjbn9BuJP74rQT4jvHafgqKY78USriJRQA=
Endpoint = [2408:4001:xxx:深圳节点IPv6]:33333
AllowedIPs = 10.0.0.3/32, 192.168.30.0/24
PersistentKeepalive = 25
```

### 2. 上海网关节点配置：`/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.0.0.2/8
ListenPort = 22222
PrivateKey = gIzVoUosXLaNNApwYi973chTL8RKQcHreSrrpMEbtms=

PostUp = ip route replace 192.168.10.0/24 dev wg0 src 192.168.20.221
PostUp = ip route replace 192.168.30.0/24 dev wg0 src 192.168.20.221

# 对端 1：杭州
[Peer]
PublicKey = JgypDAlkI+ZGL5qlHn703+/X7DJiwsp5eCOrILVAAAw=
Endpoint = [2408:4001:xxx:杭州节点IPv6]:11111
AllowedIPs = 10.0.0.1/32, 192.168.10.0/24
PersistentKeepalive = 25

# 对端 2：深圳
[Peer]
PublicKey = ZDiVSD3XyDjbn9BuJP74rQT4jvHafgqKY78USriJRQA=
Endpoint = [2408:4001:xxx:深圳节点IPv6]:33333
AllowedIPs = 10.0.0.3/32, 192.168.30.0/24
PersistentKeepalive = 25
```

### 3. 深圳网关节点配置：`/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.0.0.3/8
ListenPort = 33333
PrivateKey = mDA/gAomXWyMJOZMUusyHLOpYGPnK69e9PiqziHOwls=

PostUp = ip route replace 192.168.10.0/24 dev wg0 src 192.168.30.56
PostUp = ip route replace 192.168.20.0/24 dev wg0 src 192.168.30.56

# 对端 1：杭州
[Peer]
PublicKey = JgypDAlkI+ZGL5qlHn703+/X7DJiwsp5eCOrILVAAAw=
Endpoint = [2408:4001:xxx:杭州节点IPv6]:11111
AllowedIPs = 10.0.0.1/32, 192.168.10.0/24
PersistentKeepalive = 25

# 对端 2：上海
[Peer]
PublicKey = YrxylafhFJblpUL+Br5KYcF+VeoJsDwlPCvxKnVDtkk=
Endpoint = [2408:4001:xxx:上海节点IPv6]:22222
AllowedIPs = 10.0.0.2/32, 192.168.20.0/24
PersistentKeepalive = 25
```

---

## 四、一键网关初始化与自启脚本

在各地域网关节点上，可使用以下统一的初始化脚本快速部署：

```bash
#!/usr/bin/env bash
# /root/init_wireguard_gateway.sh
set -euo pipefail

echo "==> [1/4] 安装 WireGuard 工具集..."
dnf -y install wireguard-tools

echo "==> [2/4] 配置内核 IP 转发..."
cat << 'EOF' > /etc/sysctl.d/99-wireguard-gateway.conf
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/99-wireguard-gateway.conf

echo "==> [3/4] 检查 /etc/wireguard/wg0.conf 是否就绪..."
if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "错误: 请先将配置写入 /etc/wireguard/wg0.conf 后再执行启动！"
    exit 1
fi
chmod 600 /etc/wireguard/wg0.conf

echo "==> [4/4] 启动并设置 WireGuard 开机自启..."
systemctl daemon-reload
systemctl enable --now wg-quick@wg0

echo "==> 网关部署完成！当前 WireGuard 状态："
wg show
```

---

## 五、子网普通业务实例互通测试（业务透明验证）

这是本架构最核心的价值体现：**子网内的其他机器（如测试机）完全不需要知道 WireGuard 的存在，直接通信即可打通。**

### 1. 测试机环境确认
登录杭州测试机（例如 `192.168.10.x`）：
```bash
# 确认测试机没有安装 WireGuard，没有额外虚拟网卡
ip -brief address show
# 预期仅有 lo 与 eth0
```

### 2. 跨地域原生 IPv4 Ping 测试
在**杭州测试机**上直接向上海和深圳的测试机发起 Ping：
```bash
# 1. 测试访问上海子网机器
ping -c 4 192.168.20.xxx

# 2. 测试访问深圳子网机器
ping -c 4 192.168.30.xxx
```
> **现象与原理**：
> 1. 数据包从测试机发出，查询默认路由送往 VPC 网关；
> 2. 阿里云 VPC 交换机命中自定义路由条目（`192.168.20.0/24 -> 杭州 WG 网关`）；
> 3. 杭州 WG 网关接收到目的为 `192.168.20.xxx` 的报文，匹配到 `wg0` 路由，封装为公网 IPv6 UDP 数据流发往上海；
> 4. 上海 WG 网关解密出原始报文，转交上海 VPC 交换机送达上海测试机；
> 5. 回包沿上海路由表对称原路返回，全程延迟通常在 20ms~35ms 之间（视地域物理距离）。

### 3. 高层协议与端口互通测试 (HTTP / TCP)
在**上海测试机**上启动临时 HTTP 服务：
```bash
python3 -m http.server 8080
```
在**杭州测试机**上直接通过私网 IPv4 访问：
```bash
curl -I http://192.168.20.xxx:8080
# 预期输出: HTTP/1.0 200 OK
```

### 4. 网关节点双向抓包排障指引
如果在测试过程中遇到不通，可在**杭州 WG 网关节点**上开启抓包观察数据流：

* **观察是否收到测试机发来的内网 IPv4 包**：
  ```bash
  tcpdump -i eth0 -nn -v icmp
  ```
  如果能看到 `192.168.10.xxx > 192.168.20.xxx`，说明云端 VPC 路由表已成功将子网流量引流至网关。

* **观察 IPv4 包是否被送入 WireGuard 隧道**：
  ```bash
  tcpdump -i wg0 -nn -v icmp
  ```
  如果能看到 ICMP request，说明网关内核 `net.ipv4.ip_forward = 1` 正常工作，且 WireGuard `AllowedIPs` 匹配成功。

* **观察是否发出外网 IPv6 UDP 加密报文**：
  ```bash
  tcpdump -i eth0 ip6 and udp port 11111 -nn
  ```
  如果能看到杭州与上海/深圳之间的公网 IPv6 UDP 交互报文，说明 Underlay 通道通信完全正常。

* **MTU 极限测试与 ICMP Fragmentation Needed 验证**：
  有关 MTU 计算公式、1392 字节临界点测试、`Frag needed and DF set` 报错验证及 TCP MSS 钳制最佳实践，请参见独立文档：[WIREGUARD_MTU_TESTING.md](./WIREGUARD_MTU_TESTING.md)。
