# WireGuard Hub & Spoke（星型拓扑）集中出网与分支内网中转实战指南

本文档介绍如何在保持底层阿里云 VPC 和 Terraform 基础设施**零变更**的前提下，将原 Full-Mesh 拓扑重构为**以深圳网关为中心（Hub）、杭州与上海为分支（Spokes）的星型集中出网与分支互联架构**。

---

## 一、网络架构与参数矩阵

### 1. 架构拓扑图

```text
                                +-----------------------------------+
                                |     深圳中心节点 (Shenzhen Hub)     |
                                | Public: 47.112.215.79:12345       |
                                | VPC: 192.168.30.81/24             |
                                | WG:  10.0.0.254/24                |
                                | 角色: 集中出网出口 + 分支间中转路由器 |
                                +-----------------+-----------------+
                                                 / \
                    +---------------------------+   +---------------------------+
                    | WireGuard Tunnel              | WireGuard Tunnel
                    | AllowedIPs: 0.0.0.0/0         | AllowedIPs: 0.0.0.0/0
                    v                               v
+-----------------------------------+             +-----------------------------------+
|     杭州分支节点 (Hangzhou Spoke)  |             |     上海分支节点 (Shanghai Spoke)  |
| Public: 118.178.88.118:12345      |             | Public: 8.133.248.185:12345       |
| VPC: 192.168.10.20/24             |             | VPC: 192.168.20.98/24             |
| WG:  10.0.0.1/24                  |             | WG:  10.0.0.2/24                  |
+-----------------+-----------------+             +-----------------+-----------------+
                  |                                                 |
       (VPC: 192.168.10.0/24)                            (VPC: 192.168.20.0/24)
                  v                                                 v
         [杭州测试机 / 业务集群]                           [上海测试机 / 业务集群]
```

### 2. 节点参数与 IP 映射对照表

| 节点角色 | 地域 | 节点标识 | 公网 IP (Public) | 监听端口 | 本地 VPC 网段 | 本地私网 IP | WireGuard 隧道 IP | 对应关系说明 | 公钥 (Public Key) | 私钥 (Private Key) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **中心节点 (Hub)** | **深圳** | Node 3 | `47.112.215.79` | `12345` | `192.168.30.0/24` | `192.168.30.81` | `10.0.0.254/24` | 经典中心网关 IP `.254` | `ZDiVSD3XyDjbn9BuJP74rQT4jvHafgqKY78USriJRQA=` | `mDA/gAomXWyMJOZMUusyHLOpYGPnK69e9PiqziHOwls=` |
| **分支节点 (Spoke 1)** | **杭州** | Node 1 | `118.178.88.118` | `12345` | `192.168.10.0/24` | `192.168.10.20` | `10.0.0.1/24` | `192.168.10` $\longleftrightarrow$ `.1` | `JgypDAlkI+ZGL5qlHn703+/X7DJiwsp5eCOrILVAAAw=` | `8FUTTteai08Hwe1Cq8oFgOYFWO+G7Sma5kYKNUjpa0g=` |
| **分支节点 (Spoke 2)** | **上海** | Node 2 | `8.133.248.185` | `12345` | `192.168.20.0/24` | `192.168.20.98` | `10.0.0.2/24` | `192.168.20` $\longleftrightarrow$ `.2` | `YrxylafhFJblpUL+Br5KYcF+VeoJsDwlPCvxKnVDtkk=` | `gIzVoUosXLaNNApwYi973chTL8RKQcHreSrrpMEbtms=` |
| **扩展客户端** | 任意 | Client N | 动态 / 内网 | - | 动态 | - | `10.0.0.x/24` | 后续任意新增节点 | 动态生成 | 动态生成 |

---

## 二、核心网络机制与深度原理剖析

### 1. 双级精准 NAT 架构（集中出网与内网互通解耦）

为了实现“公网流量集中走深圳出网，内网机器互访保留真实内网 IP”，网络采用了**双级精准 NAT 策略**：

#### (1) 一级 NAT（分支网关层）：精确区分公网与私网
在杭州与上海分支网关的 iptables 中，增加排除条件 `! -d 192.168.0.0/16`：
```bash
# 杭州网关规则：
iptables -t nat -A POSTROUTING -o wg0 ! -d 192.168.0.0/16 -j SNAT --to-source 10.0.0.1
```
- **公网流量（发往非 192.168.0.0/16 地址）**：
  命中规则，源 IP 被 SNAT 为隧道接口 IP `10.0.0.1`，通过 WireGuard 加密发往深圳。
- **内网互访流量（发往上海 192.168.20.0/24）**：
  目标地址落在 `192.168.0.0/16` 范围内，**被规则自动排除、不执行 SNAT**，保留原生源 IP（如 `192.168.10.100`）发往深圳中转。

#### (2) 二级 NAT（中心网关层）：统一伪装出网
深圳中心网关接收到来自 `10.0.0.1` 或 `10.0.0.2` 发往公网的数据包后，通过内核路由到 `eth0` 出接口：
```bash
# 深圳中心网关规则：
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
```
将源 IP 伪装为深圳网关的私网 IP `192.168.30.81`，经阿里云深圳 VPC 集中访问互联网。公网目标服务器看到的来源 IP 均为深圳公网 IP `47.112.215.79`。

---

### 2. 深圳中心节点中转路由机制（Transit Routing）

本方案中，深圳网关和深圳本地 `192.168.30.0/24` **绝不需要主动发起**对杭州与上海的访问。其中心节点配置具备极简与高可靠特性：

1. **中转转发核心开关**：
   开启 Linux 系统转发 `net.ipv4.ip_forward = 1`。
2. **为什么深圳不主动访问分支，Peer 配置仍必须声明 AllowedIPs？**
   在 WireGuard 的 **密码学路由（Cryptokey Routing）** 机制中：
   - **入站防伪造校验（Anti-Spoofing）**：杭州机器（`192.168.10.x`）发往上海的包到达深圳网关解密后，WireGuard 必须校验发送方 Peer 的 `AllowedIPs` 是否包含 `192.168.10.0/24`。如果不声明，内核会判定为非法仿冒包并直接丢弃。
   - **发往目标分支的出口决策（Hairpinning）**：深圳网关解密出目标为上海（`192.168.20.x`）的包后，正是根据上海 Peer 的 `AllowedIPs` 包含了 `192.168.20.0/24`，才能准确将报文加密发送给上海分支。

---

### 3. 终极策略路由设计：`PostUp` + `Priority 100` + `sport 22`（内核级机理解密）

> [!IMPORTANT]
> **经典大坑背景**：当在分支网关将默认路由指向 WireGuard（`AllowedIPs = 0.0.0.0/0`）时，如果外部管理员通过公网 IP SSH 访问分支网关，回包若走 WireGuard 送往深圳出口，会导致**非对称路由（Asymmetric Routing）**，造成公网 SSH 瞬间永久失联！

在实战排查中，我们从 Linux 内核源码层面彻底吃透了策略路由的分配机理，得出了最稳健的最终定稿配置：

```bash
PostUp = ip rule add from <本机私网IP> sport 22 table main priority 100 || true
```

#### 深度原理解密：为什么必须放在 `PostUp`，而绝对不能放在 `PreUp`？

我们在 Linux 内核网络路由源码（`net/core/fib_rules.c`）中发现了决定性逻辑：

```c
/* Linux 内核源码: net/core/fib_rules.c */
u32 fib_default_rule_pref(struct fib_rules_ops *ops)
{
	struct fib_rule *rule;

	if (!list_empty(&ops->rules_list)) {
		rule = list_entry(ops->rules_list.next, struct fib_rule, list);
		if (rule->pref)
			return rule->pref - 1;   /* 关键: 当未指定优先级时，内核取当前最小非0规则并减 1！ */
	}

	return 0;
}
```

而在 `wg-quick/linux.bash` 源码中，`wg-quick` 添加引流规则时**从未指定 priority 参数**：
```bash
cmd ip $proto rule add not fwmark $table table $table
cmd ip $proto rule add table main suppress_prefixlength 0
```

1. **如果在 `PreUp` 中指定规则（例如设为 50 或 90）会发生什么灾难？**
   - 当 `PreUp` 先执行并添加了 `priority 50` 规则后；
   - 随后 `wg-quick` 运行，调用无 priority 的 `ip rule add`；
   - 内核检查当前系统除 0 以外最小的规则是 50，触发 `rule->pref - 1`，自动为 `wg-quick` 分配 **`49` 和 `48`**！
   - **结果：无论您在 `PreUp` 里设多小的数字，`wg-quick` 永远会自动减 1 抢先骑在您的规则头上，导致自定义规则被彻底截胡失效！**

2. **为什么写在 `PostUp` 能完美终结这个死循环？**
   - 当 `wg-quick` 执行时，系统内没有小数字规则干扰，内核基于系统默认规则（32766）自动计算分配，`wg-quick` 的优先级固定为 **`32764` 和 `32765`**；
   - 紧接着进入 `PostUp`，我们显式注入 `priority 100`；
   - **100 远小于 32764**，我们的规则稳稳排在 `wg-quick` 前面；
   - **最关键的是：`wg-quick` 此时已经执行完毕，内核再也没有机会去触发 `pref - 1` 抢先了！**

3. **为什么必须精准指定 `sport 22`？**
   - 本机发起的业务出站流量（如 `curl cip.cc`、`dnf update`）：源端口是内核随机分配的高位端口，不等于 22，**跳过 100 规则，命中 32765 规则走 WireGuard 深圳出网**；
   - 外部公网 SSH 连入的回包：sshd 响应的源端口固定为 22，源 IP 为网卡 IP，**精准命中 100 规则，查 main 表从本地 `eth0` 原路返回，SSH 永不卡死**！

4. **为什么上海内网机器访问杭州 22 端口绝不会走错网卡？**
   - 上海机器（`192.168.20.x`）内网访问杭州 22 端口，回包即便命中 100 规则进入 `table main`；
   - 在 `table main` 内部，通往上海的是精准的明细路由：`192.168.20.0/24 dev wg0`；
   - 根据**最长前缀匹配原则（Longest Prefix Match）**，`/24` 优先级高于默认路由 `/0`，下一跳精准锁定 `wg0` 返回上海，**绝不会被误甩到 `eth0`**！

#### 全场景流量行为最终判定矩阵：

| 流量场景 | 是否匹配 `from <私网IP> sport 22` | 匹配规则与出接口 | 最终网络表现 |
| :--- | :--- | :--- | :--- |
| **外界公网 SSH 连入网关** | **匹配**（源端口 22，源 IP 网卡 IP） | 命中 100 规则，查 `table main` 走 `eth0` | 严格原路返回，**会话零卡死，永不掉线** |
| **网关本机主动访问互联网 (curl / dnf)** | **不匹配**（源端口为随机高位端口） | 命中 32765 规则，查 `table 51820` 走 `wg0` | 经深圳二级 SNAT，**统一走深圳公网出口** |
| **上海机器访问杭州网关 22 端口** | **匹配**（查 main 表匹配 `/24` 明细） | `table main` 中匹配 `192.168.20.0/24 dev wg0` | 经深圳中转，**内网原生直通** |
| **子网普通测试机访问互联网** | **不匹配**（源 IP 为测试机 IP，非网关 IP） | 走 `wg0` 一级 SNAT 为 `10.0.0.x` | 经深圳二级 SNAT，**统一走深圳公网出口** |
| **子网普通测试机跨地域内网互访** | **不匹配** | 走 `wg0` 原生内网路由转发 | 跨地域原生私网直通，**保留内网源 IP** |

---

## 三、各节点生产级持久化配置

所有配置均写在 `/etc/wireguard/wg0.conf` 中，可通过 `systemctl enable --now wg-quick@wg0` 纳入守护。

### 1. 深圳中心节点（Hub 网关）配置

编辑 `/etc/wireguard/wg0.conf`：

```ini
[Interface]
Address = 10.0.0.254/24
# 监听端口，可保持 12345 或 33333 (需与分支 Peer 中的 Endpoint 端口保持一致)
ListenPort = 12345
PrivateKey = mDA/gAomXWyMJOZMUusyHLOpYGPnK69e9PiqziHOwls=

# 1. 开启内核转发，允许作为中转路由器
PostUp = sysctl -w net.ipv4.ip_forward=1

# 2. 防火墙转发放行：允许 wg0 内部中转 (杭州<->上海) 以及 wg0 到公网 (eth0)
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT

# 3. 集中出网二级 NAT：将分支发来的公网流量伪装为深圳 eth0 私网 IP 经阿里云出公网
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# 停止服务时清理
PreDown = iptables -D FORWARD -i wg0 -j ACCEPT
PreDown = iptables -D FORWARD -o wg0 -j ACCEPT
PreDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# 分支节点 1：杭州网关 (Spoke 1)
[Peer]
PublicKey = JgypDAlkI+ZGL5qlHn703+/X7DJiwsp5eCOrILVAAAw=
Endpoint = 118.178.88.118:12345
AllowedIPs = 10.0.0.1/32, 192.168.10.0/24
PersistentKeepalive = 25

# 分支节点 2：上海网关 (Spoke 2)
[Peer]
PublicKey = YrxylafhFJblpUL+Br5KYcF+VeoJsDwlPCvxKnVDtkk=
Endpoint = 8.133.248.185:12345
AllowedIPs = 10.0.0.2/32, 192.168.20.0/24
PersistentKeepalive = 25
```

---

### 2. 杭州分支节点（Spoke 1 网关）配置

编辑 `/etc/wireguard/wg0.conf`：

```ini
[Interface]
Address = 10.0.0.1/24
ListenPort = 12345
PrivateKey = 8FUTTteai08Hwe1Cq8oFgOYFWO+G7Sma5kYKNUjpa0g=

PostUp = sysctl -w net.ipv4.ip_forward=1
# 1. 核心高可靠防断连：在 PostUp 中指定 priority 100，永久领先并压制 wg-quick 的 32764/32765 规则
# 提示：请将 192.168.10.20 替换为您杭州网关 eth0 的实际私网 IP
PostUp = ip rule add from 192.168.10.20 sport 22 table main priority 100 || true

# 2. 转发链放通
PostUp = iptables -A FORWARD -i eth0 -o wg0 -j ACCEPT
PostUp = iptables -A FORWARD -i wg0 -o eth0 -j ACCEPT

# 3. 一级 SNAT：访问公网做 NAT 改为 10.0.0.1；发往 192.168.0.0/16 的内网互通保持原生私网 IP
PostUp = iptables -t nat -A POSTROUTING -o wg0 ! -d 192.168.0.0/16 -j SNAT --to-source 10.0.0.1

# 4. 网关本机访问上海 VPC 时的源地址约束 (上海内网由深圳中转)
PostUp = ip route replace 192.168.20.0/24 dev wg0 src 192.168.10.20

# 停止服务时清理
PostDown = ip rule del from 192.168.10.20 sport 22 table main priority 100 || true
PostDown = iptables -D FORWARD -i eth0 -o wg0 -j ACCEPT || true
PostDown = iptables -D FORWARD -i wg0 -o eth0 -j ACCEPT || true
PostDown = iptables -t nat -D POSTROUTING -o wg0 ! -d 192.168.0.0/16 -j SNAT --to-source 10.0.0.1 || true

# 中心节点：深圳网关 (Hub) - 所有未被本地直连匹配的公网及内网流量统一发往深圳
[Peer]
PublicKey = ZDiVSD3XyDjbn9BuJP74rQT4jvHafgqKY78USriJRQA=
Endpoint = 47.112.215.79:12345
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

---

### 3. 上海分支节点（Spoke 2 网关）配置

编辑 `/etc/wireguard/wg0.conf`：

```ini
[Interface]
Address = 10.0.0.2/24
ListenPort = 12345
PrivateKey = gIzVoUosXLaNNApwYi973chTL8RKQcHreSrrpMEbtms=

PostUp = sysctl -w net.ipv4.ip_forward=1
# 1. 核心高可靠防断连：在 PostUp 中指定 priority 100，永久领先并压制 wg-quick 的 32764/32765 规则
# 提示：请将 192.168.20.98 替换为您上海网关 eth0 的实际私网 IP
PostUp = ip rule add from 192.168.20.98 sport 22 table main priority 100 || true

# 2. 转发链放通
PostUp = iptables -A FORWARD -i eth0 -o wg0 -j ACCEPT
PostUp = iptables -A FORWARD -i wg0 -o eth0 -j ACCEPT

# 3. 一级 SNAT：访问公网做 NAT 改为 10.0.0.2；发往 192.168.0.0/16 的内网互通保持原生私网 IP
PostUp = iptables -t nat -A POSTROUTING -o wg0 ! -d 192.168.0.0/16 -j SNAT --to-source 10.0.0.2

# 4. 网关本机访问杭州 VPC 时的源地址约束 (杭州内网由深圳中转)
PostUp = ip route replace 192.168.10.0/24 dev wg0 src 192.168.20.98

# 停止服务时清理
PostDown = ip rule del from 192.168.20.98 sport 22 table main priority 100 || true
PostDown = iptables -D FORWARD -i eth0 -o wg0 -j ACCEPT || true
PostDown = iptables -D FORWARD -i wg0 -o eth0 -j ACCEPT || true
PostDown = iptables -t nat -D POSTROUTING -o wg0 ! -d 192.168.0.0/16 -j SNAT --to-source 10.0.0.2 || true

# 中心节点：深圳网关 (Hub)
[Peer]
PublicKey = ZDiVSD3XyDjbn9BuJP74rQT4jvHafgqKY78USriJRQA=
Endpoint = 47.112.215.79:12345
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

---

### 4. 服务重启与生效

在三台节点分别执行重启以应用新配置：

```bash
# 停止旧隧道
sudo wg-quick down wg0

# 启动新隧道
sudo wg-quick up wg0

# 设置开机自启
sudo systemctl enable wg-quick@wg0
```

---

## 四、未来新增客户端接入标准模板（10.0.0.x/24）

得益于星型架构的高内聚性，后续新增任何客户端节点（如运维笔记本、新地域 VPC 网关、分支办公室），只需两步操作：

### 1. 客户端生成密钥并创建配置
假设新增客户端为 Node 4，分配 IP `10.0.0.4/24`：

```ini
[Interface]
Address = 10.0.0.4/24
PrivateKey = <客户端私钥>

# 中心节点：深圳
[Peer]
PublicKey = ZDiVSD3XyDjbn9BuJP74rQT4jvHafgqKY78USriJRQA=
Endpoint = 47.112.215.79:12345
# 如果需要全局流量走深圳出网:
AllowedIPs = 0.0.0.0/0
# 如果仅需要访问内网 (杭州/上海/深圳) 不代理公网:
# AllowedIPs = 10.0.0.0/24, 192.168.10.0/24, 192.168.20.0/24, 192.168.30.0/24
PersistentKeepalive = 25
```

### 2. 深圳中心网关追加 Peer
在深圳网关 `/etc/wireguard/wg0.conf` 末尾追加，热重载即可：

```ini
[Peer]
PublicKey = <客户端公钥>
AllowedIPs = 10.0.0.4/32
```
热重载命令（无需中断现有连接）：
```bash
sudo wg syncconf wg0 <(wg-quick strip wg0)
```

---

## 五、子网普通业务实例（测试机）引流操作

### 1. 为什么在云上直接修改 `ip route replace default via 网关IP` 无效？
在传统物理局域网（二层交换机）中，修改操作系统的默认网关指向同网段另一台机器后，只要二层 MAC 目标是网关，网关就能收到数据包并代为路由。

但在**公有云（阿里云 VPC / AWS VPC）环境**下：
- 底层虚拟交换机（vSwitch）是**三层 SDN 虚拟路由**，不是传统物理交换机。
- 当测试机本身分配了公网 IP（`118.178.143.104`）时，系统发出的公网数据包（如发往 `cip.cc`）一出网卡 Tap 口，宿主机 SDN 就会根据三层目的 IP 匹配 VPC 路由表（`0.0.0.0/0 -> Ipv4Gateway`），强制直接送入公网网关做 1:1 NAT，**完全忽略了操作系统填写的下一跳 MAC 地址（网关 ECS MAC）**。
- 因此，在公有云同子网内，**无法仅靠操作系统层的静态 ARP/默认路由实现跨实例三层公网代流**。

---

### 2. 方案 A：操作系统层【IPIP 隧道引流】（零修改云网络 / 零改动 Terraform）
通过在测试机与网关机之间建立极低开销的 **IPIP 隧道（IP-in-IP 封装）**：
- 测试机发往公网的数据包被穿上一层内网外衣（外层目标 IP 为网关私网 IP `192.168.10.20`）；
- 阿里云 vSwitch 识别到是同 VPC 内网互访，直接将外层数据包送达网关机；
- 网关机内核解封装后获得原始公网包，走 `wg0` 隧道送至深圳中心统一出网。

#### 步骤一：在杭州网关机 (`192.168.10.20`) 上配置隧道接收
```bash
# 1. 加载内核 IPIP 模块并创建对端隧道接口
sudo modprobe ipip
sudo ip tunnel add tun-test mode ipip remote 192.168.10.19 local 192.168.10.20
sudo ip link set tun-test up

# 2. 添加回包路由（确保从深圳返回发往测试机的数据包走隧道返回）
sudo ip route replace 192.168.10.19/32 dev tun-test

# 3. 防火墙放通隧道接口转发
sudo iptables -A FORWARD -i tun-test -o wg0 -j ACCEPT
sudo iptables -A FORWARD -i wg0 -o tun-test -j ACCEPT
```

#### 步骤二：在杭州测试机 (`192.168.10.19`) 上配置引流
```bash
# 1. 核心安全防护：保留 SSH 独立返回原生网关，防止切换默认路由导致当前 SSH 断连
sudo ip rule add from 192.168.10.19 sport 22 table main priority 100 || true

# 2. 加载 IPIP 模块并建立指向网关机的隧道
sudo modprobe ipip
sudo ip tunnel add tun0 mode ipip remote 192.168.10.20 local 192.168.10.19 dev eth0
sudo ip link set tun0 up

# 3. 将测试机默认网关切换为 tun0 隧道
sudo ip route replace default dev tun0

# 4. 验证公网出口（此时应显示深圳网关公网 IP 47.112.215.79）
curl cip.cc
```

#### 步骤三：测试机恢复默认网络命令
若测试完毕需要恢复测试机直连出网：
```bash
# 恢复阿里云原生网关
sudo ip route replace default via 192.168.10.253 dev eth0
sudo ip tunnel del tun0
```

---

### 3. 方案 B：云平台架构【VPC 路由表引流】（云原生标准生产模式）
在正式生产环境中，普通业务机器通常**不分配公网 IP**（纯内网实例），由云平台 VPC 路由表统一调度：
1. **自定义子网路由表**：
   在阿里云 VPC 路由表中，添加自定义路由条目：
   - 目标网段：`0.0.0.0/0`
   - 下一跳类型：`ECS 实例`（选择杭州 WireGuard 网关 ECS）
2. **防环路明细路由（关键）**：
   由于网关 ECS 自身需要通过公网连接深圳（`47.112.215.79:12345`），必须在路由表中配置一条优先级更高的明细主机路由：
   - 目标网段：`47.112.215.79/32`
   - 下一跳类型：`IPv4 网关`
   这样网关自身连接深圳的握手流量直接出公网，子网其余流量全部流向网关 ECS。

---

## 六、全网连通性验证与抓包诊断排错手册

### 1. 验证 WireGuard 握手状态
在各节点执行 `wg show`：
- **深圳网关**：应显示有两个 Peer（杭州与上海），`latest handshake` 均在几十秒内，收发流量双向增长。
- **杭州与上海网关**：各自只显示一个 Peer（深圳），握手成功。

### 2. 验证集中出网出口 IP（公网出口统一为深圳）
在杭州网关机、上海网关机或已引流的测试机上执行：
```bash
curl cip.cc
# 或
curl ifconfig.me
```
**预期输出**：
```text
IP	: 47.112.215.79
地址	: 中国 广东 深圳
运营商	: 阿里云
```
返回的必须是**深圳网关机的公网 IP**，证明出网流量成功跨地域送达深圳并完成了集中二级 NAT 出网！

### 3. 验证杭州与上海内网透明中转（保留原生内网 IP）
从杭州网关（`192.168.10.20`）ping 上海网关（`192.168.20.98`）：
```bash
ping -c 4 192.168.20.98
```
在上海网关上抓包验证源地址：
```bash
sudo tcpdump -i eth0 -nn -v icmp
```
**预期捕获显示**：
```text
IP 192.168.10.20 > 192.168.20.98: ICMP echo request
IP 192.168.20.98 > 192.168.10.20: ICMP echo reply
```
源 IP 保持原生私网 IP，未被 SNAT 伪装，证明深圳中转完全透明！

### 4. 验证公网 SSH 管理通道稳定性
从本地电脑直接公网 SSH 连接杭州或上海网关：
```bash
# 连接杭州网关
ssh root@118.178.88.118

# 连接上海网关
ssh root@8.133.248.185
```
在网关上查看策略路由：
```bash
ip rule list
```
**预期输出包含**：
```text
100:	from 192.168.10.20 sport 22 lookup main    # 杭州网关
# 或
100:	from 192.168.20.98 sport 22 lookup main    # 上海网关
32764:	from all lookup main suppress_prefixlength 0
32765:	not from all fwmark 0xca6c lookup 51820
```
SSH 流量严格从本地物理网卡 `eth0` 原路返回，会话保持流畅，绝对不会发生断连或卡死。
