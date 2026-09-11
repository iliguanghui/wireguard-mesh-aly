# WireGuard 全互联（Full Mesh）多地域跨 VPC 组网实战指南

本文档涵盖网络拓扑规划、前置安装、密钥生成、底层命令行手动部署复盘、核心原理解析（路由与源地址选择）、生产级持久化配置（`wg-quick`）以及全网连通性验证。

---

## 一、网络架构与参数矩阵

三台节点分别位于阿里云**杭州**、**上海**、**深圳**地域，底层 VPC 网段各不相同，通过 WireGuard 搭建覆盖网络（Overlay Network），构建两两互联、均可主动发起通信的 Full-Mesh 全互联拓扑。

### 1. 拓扑结构图

```text
               +----------------------------------+
               |          杭州节点 (Hangzhou)       |
               |  Public: 118.178.224.253:11111   |
               |  VPC: 192.168.10.251 (/24)       |
               |  WG:  10.0.0.1/8                 |
               +-----------------+----------------+
                                / \
                               /   \
                              /     \
             WireGuard Tunnel/       \WireGuard Tunnel
                            /         \
                           /           \
                          /             \
                         /               \
                        /                 \
+----------------------+--+             +--+---------------------+
|        上海节点 (Shanghai) |             |        深圳节点 (Shenzhen) |
| Public: 47.102.24.125:22222 |<----------->| Public: 47.112.18.34:33333 |
| VPC: 192.168.20.221 (/24)   | WireGuard   | VPC: 192.168.30.56 (/24)   |
| WG:  10.0.0.2/8             | Tunnel      | WG:  10.0.0.3/8            |
+-----------------------------+             +----------------------------+
```

### 2. 节点参数对照表

| 节点标识 | 阿里云地域 | 公网 IP (Public) | 监听端口 | 本地 VPC 网段 | 本地私网 IP | WireGuard 隧道 IP | 公钥 (Public Key) | 私钥 (Private Key) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Node 1** | **杭州** | `118.178.224.253` | `11111` | `192.168.10.0/24` | `192.168.10.251` | `10.0.0.1/8` | `JgypDAlkI+ZGL5qlHn703+/X7DJiwsp5eCOrILVAAAw=` | `8FUTTteai08Hwe1Cq8oFgOYFWO+G7Sma5kYKNUjpa0g=` |
| **Node 2** | **上海** | `47.102.24.125` | `22222` | `192.168.20.0/24` | `192.168.20.221` | `10.0.0.2/8` | `YrxylafhFJblpUL+Br5KYcF+VeoJsDwlPCvxKnVDtkk=` | `gIzVoUosXLaNNApwYi973chTL8RKQcHreSrrpMEbtms=` |
| **Node 3** | **深圳** | `47.112.18.34` | `33333` | `192.168.30.0/24` | `192.168.30.56` | `10.0.0.3/8` | `ZDiVSD3XyDjbn9BuJP74rQT4jvHafgqKY78USriJRQA=` | `mDA/gAomXWyMJOZMUusyHLOpYGPnK69e9PiqziHOwls=` |

---

## 二、前置准备与环境检查

### 1. 安装管理工具

Fedora 官方内核（Linux 5.6+）已内置 WireGuard 内核模块，仅需安装用户态工具链 `wireguard-tools`：

```bash
sudo dnf -y install wireguard-tools
```

### 2. 验证内核模块

```bash
lsmod | grep wireguard
```

> 若无输出，运行 `modprobe wireguard` 或在初次创建 `wg0` 网卡时由内核自动加载。

### 3. 云厂商安全组放行

确保阿里云安全组已放行各地域实例的 UDP 监听端口：
- 杭州：UDP `11111`
- 上海：UDP `22222`
- 深圳：UDP `33333`

> 本项目 Terraform 代码中使用了全通安全组（放行一切协议与端口），无需额外补充规则。

---

## 三、生成 WireGuard 密钥对

在每台主机上生成专属的公私钥对，并妥善保管私钥权限：

```bash
# 1. 确保在安全工作目录
cd /etc/wireguard/ || mkdir -p /etc/wireguard && cd /etc/wireguard

# 2. 生成私钥并设置严格权限 (600)
wg genkey | tee private.key
chmod 600 private.key

# 3. 从私钥派生出公钥
wg pubkey < private.key > public.key
chmod 644 public.key

# 4. 查看当前节点的公钥 (交换给其他节点使用)
cat public.key
```

---

## 四、底层命令行手动配置（历史过程复盘）

本节完整复现并规范化历史操作记录中的底层指令。

### 1. 杭州节点 (Node 1)

```bash
# 1. 创建虚拟网卡并分配隧道 IP
ip link add dev wg0 type wireguard
ip addr add 10.0.0.1/8 dev wg0

# 2. 配置本地监听端口与私钥，并添加上海与深圳对端
wg set wg0 listen-port 11111 private-key ./private.key \
  peer YrxylafhFJblpUL+Br5KYcF+VeoJsDwlPCvxKnVDtkk= \
    endpoint 47.102.24.125:22222 \
    allowed-ips 192.168.20.0/24,10.0.0.2/32 \
  peer ZDiVSD3XyDjbn9BuJP74rQT4jvHafgqKY78USriJRQA= \
    endpoint 47.112.18.34:33333 \
    allowed-ips 192.168.30.0/24,10.0.0.3/32

# 3. 启用网卡
ip link set dev wg0 up

# 4. 注入远端 VPC 路由，并指定首选源地址为本地 VPC IP (关键步骤)
ip route add 192.168.20.0/24 dev wg0 src 192.168.10.251
ip route add 192.168.30.0/24 dev wg0 src 192.168.10.251
```

### 2. 上海节点 (Node 2)

```bash
# 1. 创建虚拟网卡并分配隧道 IP
ip link add dev wg0 type wireguard
ip addr add 10.0.0.2/8 dev wg0

# 2. 配置本地监听端口与私钥，并添加杭州与深圳对端
wg set wg0 listen-port 22222 private-key ./private.key \
  peer JgypDAlkI+ZGL5qlHn703+/X7DJiwsp5eCOrILVAAAw= \
    endpoint 118.178.224.253:11111 \
    allowed-ips 192.168.10.0/24,10.0.0.1/32 \
  peer ZDiVSD3XyDjbn9BuJP74rQT4jvHafgqKY78USriJRQA= \
    endpoint 47.112.18.34:33333 \
    allowed-ips 192.168.30.0/24,10.0.0.3/32

# 3. 启用网卡
ip link set dev wg0 up

# 4. 注入远端 VPC 路由，并指定首选源地址为本地 VPC IP
ip route add 192.168.10.0/24 dev wg0 src 192.168.20.221
ip route add 192.168.30.0/24 dev wg0 src 192.168.20.221
```

### 3. 深圳节点 (Node 3)

```bash
# 1. 创建虚拟网卡并分配隧道 IP
ip link add dev wg0 type wireguard
ip addr add 10.0.0.3/8 dev wg0

# 2. 配置本地监听端口与私钥，并添加杭州与上海对端
wg set wg0 listen-port 33333 private-key ./private.key \
  peer JgypDAlkI+ZGL5qlHn703+/X7DJiwsp5eCOrILVAAAw= \
    endpoint 118.178.224.253:11111 \
    allowed-ips 192.168.10.0/24,10.0.0.1/32 \
  peer YrxylafhFJblpUL+Br5KYcF+VeoJsDwlPCvxKnVDtkk= \
    endpoint 47.102.24.125:22222 \
    allowed-ips 192.168.20.0/24,10.0.0.2/32

# 3. 启用网卡
ip link set dev wg0 up

# 4. 注入远端 VPC 路由，并指定首选源地址为本地 VPC IP
ip route add 192.168.10.0/24 dev wg0 src 192.168.30.56
ip route add 192.168.20.0/24 dev wg0 src 192.168.30.56
```

---

## 五、核心避坑点与技术原理剖析

操作记录中，排障过程经历了多次 `tcpdump`、`ping` 和路由修改，提炼出以下核心技术要点：

### 1. 为什么必须指定 `src <本地VPC IP>`？

在历史命令中，最初执行的是普通添加路由：
```bash
ip route add 192.168.20.0/24 dev wg0
```
随后执行 ping 目标 VPC 私网 IP：`ping 192.168.20.221`。

#### 原理解析：Linux 首选源地址选择（Preferred Source Address）
- 当 Linux 内核准备向 `192.168.20.221` 发送报文时，查询路由表发现出接口是 `wg0`。
- 因为路由规则中**没有指定 `src` 参数**，内核会默认选择该接口绑定的主 IP 作为源地址，即 **`10.0.0.1`**。
- 此时发出的 ICMP 报文为：`SRC: 10.0.0.1 -> DST: 192.168.20.221`。
- 当目的主机收到该包时，源 IP 是 `10.0.0.1` 而不是期望的 VPC 网段 `192.168.10.251`。如果应用绑定了 VPC 私网 IP、或者安全策略仅允许 VPC 网段互访，则通信异常。
- 通过执行：
  ```bash
  ip route change 192.168.20.0/24 dev wg0 src 192.168.10.251
  ```
  强制内核将发往目标 VPC 子网报文的源 IP 设置为本地 VPC 私网 IP，实现了透明、对称的跨地域 VPC 互通。

> **技术细节（`change` 与 `replace` 的区别）**：
> - 在手动交互式命令行中，因为前面已经执行了 `ip route add`，所以后续可以使用 `ip route change` 修改已有路由。
> - 在 `wg-quick` 的持久化配置文件（`wg0.conf`）中，由于 `wg-quick` 启动时已依据 `AllowedIPs` 自动添加了该网段的基础路由，在 `PostUp` 中使用 **`ip route replace`** 可以实现幂等覆盖（存在则修改属性，不存在则直接创建），彻底避免直接使用 `add` 引发的 `RTNETLINK answers: File exists` 错误。

### 2. WireGuard 密码学路由机制（Cryptokey Routing）与 `AllowedIPs`

WireGuard 内部实现了严格的密码学路由表：
- **出站检查**：发往对端的报文目的 IP，必须落在该 Peer 的 `AllowedIPs` 范围内，否则内核直接丢弃该报文。
- **入站验证**：解密收到的报文后，检查报文的源 IP（Source IP）是否在该 Peer 的 `AllowedIPs` 列表中。如果不是，判定为伪造包直接静默丢弃。
- **配置结论**：
  因此 Peer 的 `AllowedIPs` 必须**同时包含**对端的 WireGuard 隧道 IP（如 `10.0.0.2/32`）以及对端的 VPC 子网网段（如 `192.168.20.0/24`）：
  ```text
  allowed-ips 192.168.20.0/24,10.0.0.2/32
  ```

### 3. 全互联（Full Mesh）与主动双向发起

- WireGuard 支持“端点漫游（Endpoint Roaming）”。如果 A 配置了 B 的公网 Endpoint，A 主动发包后，B 能自动学到 A 的公网 IP 与端口。
- 但如果两台节点都要能**在任何时刻任意主动发起通信**（不受先后顺序限制），则**所有节点在配置中必须对称声明所有对端的公网 `Endpoint = IP:Port`**。
- 此外，为防止云厂商 NAT 映射超时，推荐在 Peer 中开启保活机制：`PersistentKeepalive = 25`。

---

## 六、生产级持久化配置（`wg-quick` 方案）

底层命令行在服务器重启后会丢失。生产环境中推荐使用官方 `wg-quick` 工具配合 systemd 守护进程。

在 `/etc/wireguard/wg0.conf` 中，利用 `PostUp` 钩子在 `wg-quick` 根据 `AllowedIPs` 自动生成基础路由之后，使用 `replace` 覆盖指定本地 VPC 私网 IP 为首选源地址（`src`）。当 `wg-quick down` 停止时，由于网卡 `wg0` 被销毁，相关路由会被内核自动清理。

### 1. 杭州节点配置：`/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.0.0.1/8
ListenPort = 11111
PrivateKey = 8FUTTteai08Hwe1Cq8oFgOYFWO+G7Sma5kYKNUjpa0g=

# wg-quick 会自动根据 AllowedIPs 添加基础路由，此处使用 replace 覆盖并附加本地 VPC 首选源地址 (src)
PostUp = ip route replace 192.168.20.0/24 dev wg0 src 192.168.10.251
PostUp = ip route replace 192.168.30.0/24 dev wg0 src 192.168.10.251

# 对端 1：上海
[Peer]
PublicKey = YrxylafhFJblpUL+Br5KYcF+VeoJsDwlPCvxKnVDtkk=
Endpoint = 47.102.24.125:22222
AllowedIPs = 10.0.0.2/32, 192.168.20.0/24
PersistentKeepalive = 25

# 对端 2：深圳
[Peer]
PublicKey = ZDiVSD3XyDjbn9BuJP74rQT4jvHafgqKY78USriJRQA=
Endpoint = 47.112.18.34:33333
AllowedIPs = 10.0.0.3/32, 192.168.30.0/24
PersistentKeepalive = 25
```

### 2. 上海节点配置：`/etc/wireguard/wg0.conf`

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
Endpoint = 118.178.224.253:11111
AllowedIPs = 10.0.0.1/32, 192.168.10.0/24
PersistentKeepalive = 25

# 对端 2：深圳
[Peer]
PublicKey = ZDiVSD3XyDjbn9BuJP74rQT4jvHafgqKY78USriJRQA=
Endpoint = 47.112.18.34:33333
AllowedIPs = 10.0.0.3/32, 192.168.30.0/24
PersistentKeepalive = 25
```

### 3. 深圳节点配置：`/etc/wireguard/wg0.conf`

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
Endpoint = 118.178.224.253:11111
AllowedIPs = 10.0.0.1/32, 192.168.10.0/24
PersistentKeepalive = 25

# 对端 2：上海
[Peer]
PublicKey = YrxylafhFJblpUL+Br5KYcF+VeoJsDwlPCvxKnVDtkk=
Endpoint = 47.102.24.125:22222
AllowedIPs = 10.0.0.2/32, 192.168.20.0/24
PersistentKeepalive = 25
```

### 4. 服务管理与开机自启

```bash
# 启动 wg0
wg-quick up wg0

# 停止 wg0
wg-quick down wg0

# 设置 systemd 开机自启
systemctl enable wg-quick@wg0

# 立即启动并加入守护
systemctl start wg-quick@wg0
systemctl status wg-quick@wg0
```

---

## 七、全网连通性测试与验证

### 1. 查看 WireGuard 隧道与握手状态

执行 `wg` 或 `wg show`：
```bash
wg show
```
**关键观察指标**：
- `latest handshake`：如果在几秒到 2 分钟之内，说明密钥认证与握手建立成功。
- `transfer`：收发双向均有数据流（例如 `transfer: 1.25 KiB received, 1.48 KiB sent`）。

### 2. 隧道 IP 互通验证 (Ping 10.0.0.x)

在杭州节点测试：
```bash
# Ping 自身
ping -c 3 10.0.0.1

# Ping 上海
ping -c 3 10.0.0.2

# Ping 深圳
ping -c 3 10.0.0.3
```

### 3. VPC 子网私网 IP 跨地域透明互通验证 (Ping 192.168.x.x)

在任意一台主机上直接 ping 其余主机的 VPC 私网 IP：

```bash
# 杭州 (192.168.10.251) 访问上海与深圳
ping -c 3 192.168.20.221
ping -c 3 192.168.30.56

# 上海 (192.168.20.221) 访问杭州与深圳
ping -c 3 192.168.10.251
ping -c 3 192.168.30.56

# 深圳 (192.168.30.56) 访问杭州与上海
ping -c 3 192.168.10.251
ping -c 3 192.168.20.221
```

### 4. 抓包诊断分析（验证源地址选择与路由行为）

如果在通信排障过程中怀疑有丢包或源地址错误，可在 `wg0` 网卡上运行 `tcpdump`：
```bash
tcpdump -i wg0 -nn -v icmp
```
正常的 ICMP 往返报文格式应显示：
```text
IP 192.168.10.251 > 192.168.20.221: ICMP echo request, id 1, seq 1, length 64
IP 192.168.20.221 > 192.168.10.251: ICMP echo reply, id 1, seq 1, length 64
```
若源 IP 出现 `10.0.0.1`，说明本地路由尚未正确应用 `src` 约束。

### 5. 跨地域主动通信压力测试脚本复盘

在历史记录中，通过脚本循环执行 ping 检测网络抖动与双向保活状态：
```bash
#!/bin/bash
# 示例连通性巡检脚本 (/tmp/check_mesh.sh)
TARGETS=("192.168.10.251" "192.168.20.221" "192.168.30.56")

for ip in "${TARGETS[@]}"; do
  echo -n "Pinging $ip ... "
  if ping -c 1 -W 2 "$ip" > /dev/null 2>&1; then
    echo "SUCCESS"
  else
    echo "FAILED"
  fi
done
```
