# Terraform 阿里云多地域 VPC、全通安全组与极低成本 Fedora ECS 实战指南

本项目是一个专为 Terraform 学习者打造的生产级实战工程，展示了如何在阿里云的三个地域（**杭州**、**上海**、**深圳**）通过声明式代码自动创建：
1. **网络层**：专有网络（VPC，开启 IPv6 双栈）、交换机（VSwitch，分配 IPv6 子网）、**IPv4 网关（集中控制模式）**、**IPv6 网关与公网出网带宽**，以及**自定义公共路由表**（默认路由指向 IPv4 网关，跨地域子网下一跳指向本地 WireGuard 网关）。
2. **安全层**：各地域独立的**全通安全组**（放通一切 IPv4 与 IPv6 进出端口协议），导入本地 SSH 公钥。
3. **计算层**：
   - **WireGuard 网关 ECS 实例**：极低成本抢占式实例（**节省停机中断模式**、**ESSD Entry 20GB 系统盘**、**自动分配公网 IPv4 + 公网 IPv6**，按流量计费）。
   - **子网测试 ECS 实例**：每地域各 1 台（不分配 IPv6），用于验证跨地域透明内网 IPv4 互相访问。

---

## 目录结构

```text
.
├── .gitignore                # 忽略本地状态文件、插件缓存和敏感变量
├── versions.tf               # 声明 Terraform 版本及 alicloud provider 依赖
├── providers.tf              # 配置多地域 Provider 别名 (Alias)
├── variables.tf              # 声明入参变量 (地域代码、网段 CIDR、实例规格、SSH 密钥、IPv6 带宽等)
├── main.tf                   # 核心资源编排 (网络、路由、安全组、密钥对、网关与测试 ECS)
├── outputs.tf                # 定义执行成功后的输出信息 (各资源 ID、公网 IP、IPv6、测试机登录命令)
├── terraform.tfvars.example  # 变量覆盖样例文件
├── WIREGUARD_MESH.md         # WireGuard 全互联跨地域跨 VPC 组网实战指南 (IPv4 Underlay)
├── WIREGUARD_IPV6_GATEWAY.md # WireGuard 4-over-6 全互联跨地域 VPC 站点对站点网关实战指南 (IPv6 Underlay)
└── README.md                 # 学习与操作指南
```

---

## 资源规划与网络拓扑

| 地域 | 地域代码 (`region`) | VPC 网段 | 子网 (VSwitch) 网段 | 可用区策略 | 网关实例配置 (WG Gateway) | 测试机配置 (Test Instance) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **杭州** | `cn-hangzhou` | `192.168.0.0/16` | `192.168.10.0/24` | 动态过滤 (Spot+ESSD Entry) | 抢占式 + 20G ESSD + IPv4/IPv6 双公网 | 抢占式 + 20G ESSD + 仅公网 IPv4 |
| **上海** | `cn-shanghai` | `192.168.0.0/16` | `192.168.20.0/24` | 动态过滤 (Spot+ESSD Entry) | 抢占式 + 20G ESSD + IPv4/IPv6 双公网 | 抢占式 + 20G ESSD + 仅公网 IPv4 |
| **深圳** | `cn-shenzhen` | `192.168.0.0/16` | `192.168.30.0/24` | 动态过滤 (Spot+ESSD Entry) | 抢占式 + 20G ESSD + IPv4/IPv6 双公网 | 抢占式 + 20G ESSD + 仅公网 IPv4 |

---

## 核心技术与极低成本设计解析

### 1. 抢占式实例 + 节省停机中断模式 (SpotInterruptionBehavior = Stop)
- **抢占式出价 (`spot_strategy = "SpotAsPriceGo"`)**：系统自动跟随市场价竞价，通常享受按量原价 1~2 折的极高优惠。
- **中断节省停机 (`spot_interruption_behavior = "Stop"`)**：
  - 当发生市场库存不足或被系统抢占回收时，实例不会被直接释放销毁，而是自动进入节省停机状态，系统盘与数据安全保留。
  - 即使保留默认的 1 小时保护期（`SpotDuration = 1`），中断模式 `Stop` 也完全正常生效。
- **关于 `stopped_mode` 的配置避坑**：
  - `stopped_mode`（停止模式）是**实例进入主动停机状态（Stopped）后**才体现的计费模式；当实例处于运行中（Running）时，API 返回始终为 `Not-applicable`。
  - 实例创建时切勿在代码中配置 `stopped_mode = "StopCharging"`，否则会导致 Terraform 每次 plan 都出现无法消除的虚假状态漂移。该模式应当在主动停机操作时按需指定。

### 2. 最经济系统盘：ESSD Entry (20GB)
- 选用 `system_disk_category = "cloud_essd_entry"`，这是阿里云针对入门通用场景推出的超高性价比 ESSD 规格。
- 容量设为 `20` GB，为 Linux 官方镜像允许的最小容量，存储闲置成本极低。

### 3. 系统自动分配公网 IP (按流量计费)
- 无需为每台实例单独采购或绑定固定 EIP。
- 通过在 `alicloud_instance` 中配置 `internet_charge_type = "PayByTraffic"` 与 `internet_max_bandwidth_out = 5`，阿里云会在创建时自动向实例主网卡分配一个公网 IPv4 地址。
- 网关实例额外分配公网 IPv6 地址并开通按量计费公网出网带宽（`alicloud_vpc_ipv6_internet_bandwidth`）。
- 仅在有实际网络出网流量时产生按量费用（测试期间几乎为 0 元）。

### 4. 智能协同可用区过滤 (`data "alicloud_instance_types"`)
- 在阿里云官方文档中，传统 `data "alicloud_zones"` 的 `available_disk_category` 属于旧版遗留设计，无法可靠过滤新型磁盘（如 `cloud_essd_entry`）。
- 本项目采用生产级最佳实践：使用 **`data "alicloud_instance_types"`** 进行多维度联合过滤：
  - `instance_type = var.instance_type`（指定规格）
  - `system_disk_category = var.system_disk_category`（指定 `cloud_essd_entry` 系统盘）
  - `spot_strategy = var.spot_strategy`（指定 `SpotAsPriceGo` 抢占式竞价）
  - `instance_charge_type = "PostPaid"`（按量/抢占式付费）
  从返回匹配结果的 `availability_zones[0]` 中直接提取受支持的可用区传给交换机（VSwitch），彻底杜绝“可用区不支持抢占式”或“可用区不支持 ESSD Entry”等隐蔽报错。

### 5. SSH 密钥对自动导入 (`alicloud_key_pair`)
- 通过变量 `var.ssh_public_key` 注入公钥文本内容并导入各地域，兼容本地与 HCP Terraform 云端执行，注入 ECS 的 root 用户。
- 创建完成后无需密码，直接通过 `ssh root@<公网IP>` 即可无密登录。

---

## 快速上手与实战流程

### 第一步：配置阿里云 AccessKey 凭证

```bash
export ALICLOUD_ACCESS_KEY="你的阿里云AccessKeyId"
export ALICLOUD_SECRET_KEY="你的阿里云AccessKeySecret"
```

> 确保所用 RAM 账号具备 VPC、VSwitch、SecurityGroup 和 ECS 的管理权限。

---

### 第二步：预览执行计划 (`terraform plan`)

```bash
# 格式化检查
terraform fmt

# 校验合法性
terraform validate

# 试运行预览
terraform plan
```

在终端输出中，你将看到预计纳管 **57 个云端资源**（每地域 19 个资源：VPC、VSwitch、IPv4 网关、IPv6 网关、IPv6 出网带宽、自定义路由表、交换机绑定、默认 IPv4 公网路由、默认 IPv6 公网路由、2 条跨地域引流路由、安全组、2 条 IPv4 安全组规则、2 条 IPv6 安全组规则、SSH 密钥对、WireGuard 网关 ECS、测试 ECS）。

---

### 第三步：一键创建 (`terraform apply`)

```bash
terraform apply
```

输入 `yes` 确认，Terraform 会自动并发完成三地的所有网络和计算资源创建。
创建完成后，终端 outputs 会直接给出各地域的公网 IP 和 SSH 登录指令，例如：
```text
hangzhou_ssh_command = "ssh root@47.98.xxx.xxx"
shanghai_ssh_command = "ssh root@106.14.xxx.xxx"
shenzhen_ssh_command = "ssh root@120.79.xxx.xxx"
```

---

### 第四步：免密登录验证

复制终端输出的 SSH 命令直接连接即可：
```bash
ssh root@<公网IP>
```
进入后可运行 `cat /etc/os-release` 查看当前最新的 Fedora 系统信息。

---

### 第五步：一键清理与资源销毁 (`terraform destroy`)

学习测试完成后，为了彻底杜绝后续计费，只需一条命令即可自动化完成全链路清理：

```bash
terraform destroy
```
输入 `yes` 确认，Terraform 会自动按照拓扑反向顺序平滑删除 ECS、密钥、安全组、路由表、IPv4 网关和 VPC。
