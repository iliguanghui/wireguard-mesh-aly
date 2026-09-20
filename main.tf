# ==============================================================================
# 核心资源编排 (main.tf)
# ==============================================================================
# 本工程实现阿里云多地域自动化编排：
# 1. 动态实例与可用区查询 (data.alicloud_instance_types):
#    原生精准匹配：规格 (instance_type) + ESSD Entry (system_disk_category) + 抢占式 (spot_strategy)，
#    提取输出的 availability_zones[0] 作为交换机创建位置，杜绝传统 data.alicloud_zones 对新磁盘支持不全的问题。
# 2. 动态镜像查询 (data.alicloud_images): 自动拉取官方最新 Fedora x86_64 镜像。
# 3. 专有网络与子网 (alicloud_vpc / alicloud_vswitch，开启 IPv6 双栈)。
# 4. 安全出入与路由控制：
#    - IPv4 网关 (alicloud_vpc_ipv4_gateway 集中控制模式)
#    - IPv6 网关与公网带宽 (alicloud_vpc_ipv6_gateway / alicloud_vpc_ipv6_internet_bandwidth)
#    - 自定义公共路由表 (默认 IPv4/IPv6 公网路由 + 跨地域 VPC 子网下一跳指向 WireGuard 网关 ECS)
# 5. 全通安全组 (alicloud_security_group / alicloud_security_group_rule): 放通一切 IPv4 与 IPv6 协议端口。
# 6. 本地 SSH 密钥导入 (alicloud_key_pair): 导入本地 /Users/admin/.ssh/id_rsa.pub。
# 7. 计算层架构：
#    - WireGuard 网关 ECS：抢占式极低成本 + 节省停机 + ESSD Entry 20GB + 双公网 IPv4/IPv6
# ==============================================================================

# ==============================================================================
# 1. 杭州地域 (cn-hangzhou)
# ==============================================================================

# 查询杭州地域中同时支持指定规格、ESSD Entry系统盘与抢占式的实例类型及可用区列表
data "alicloud_instance_types" "hangzhou" {
  provider             = alicloud.hangzhou
  instance_type        = var.instance_type
  system_disk_category = var.system_disk_category
  instance_charge_type = "PostPaid"
  spot_strategy        = var.spot_strategy
}

# 动态查询杭州最新官方 Fedora 镜像
data "alicloud_images" "fedora_hangzhou" {
  provider    = alicloud.hangzhou
  owners      = "system"
  name_regex  = "^fedora_[0-9]+_x64"
  most_recent = true
}

# 杭州 VPC (专有网络，开启 IPv6)
resource "alicloud_vpc" "hangzhou" {
  provider    = alicloud.hangzhou
  vpc_name    = "${var.project_name}-vpc-hangzhou"
  cidr_block  = var.vpc_cidr_block
  enable_ipv6 = true
  description = "Managed by Terraform - Hangzhou VPC (IPv6 Enabled)"
}

# 杭州 VSwitch (交换机) - 开启 IPv6，创建在支持 ESSD Entry + 抢占式的可用区
resource "alicloud_vswitch" "hangzhou" {
  provider             = alicloud.hangzhou
  vswitch_name         = "${var.project_name}-vsw-hangzhou"
  vpc_id               = alicloud_vpc.hangzhou.id
  cidr_block           = var.vswitch_cidr_hangzhou
  zone_id              = data.alicloud_instance_types.hangzhou.instance_types[0].availability_zones[0]
  enable_ipv6          = true
  ipv6_cidr_block_mask = 1
  description          = "Managed by Terraform - Hangzhou VSwitch (IPv6 Enabled)"
}

# 杭州 IPv4 网关并激活（开启集中控制模式）
resource "alicloud_vpc_ipv4_gateway" "hangzhou" {
  provider                 = alicloud.hangzhou
  vpc_id                   = alicloud_vpc.hangzhou.id
  ipv4_gateway_name        = "${var.project_name}-gw-hangzhou"
  ipv4_gateway_description = "Managed by Terraform - Hangzhou IPv4 Gateway (Centralized Mode)"
  enabled                  = true
  timeouts {
    delete = "30s"
  }
}

# 杭州 IPv6 网关（开启公网 IPv6 通信底座）
resource "alicloud_vpc_ipv6_gateway" "hangzhou" {
  provider          = alicloud.hangzhou
  vpc_id            = alicloud_vpc.hangzhou.id
  ipv6_gateway_name = "${var.project_name}-ipv6gw-hangzhou"

  timeouts {
    delete = "30s"
  }
}

# 杭州自定义公共路由表
resource "alicloud_route_table" "hangzhou" {
  provider         = alicloud.hangzhou
  vpc_id           = alicloud_vpc.hangzhou.id
  route_table_name = "${var.project_name}-rtb-hangzhou"
  associate_type   = "VSwitch"
  description      = "Managed by Terraform - Hangzhou Custom Route Table"
}

# 在公共路由表中增加指向 IPv4 网关的默认公网路由
resource "alicloud_route_entry" "hangzhou" {
  provider              = alicloud.hangzhou
  route_table_id        = alicloud_route_table.hangzhou.id
  destination_cidrblock = "0.0.0.0/0"
  nexthop_type          = "Ipv4Gateway"
  nexthop_id            = alicloud_vpc_ipv4_gateway.hangzhou.id
}

# 在公共路由表中增加指向 IPv6 网关的默认公网路由
resource "alicloud_route_entry" "hangzhou_ipv6_default" {
  provider              = alicloud.hangzhou
  route_table_id        = alicloud_route_table.hangzhou.id
  destination_cidrblock = "::/0"
  nexthop_type          = "IPv6Gateway"
  nexthop_id            = alicloud_vpc_ipv6_gateway.hangzhou.ipv6_gateway_id
}

# 跨地域 VPC 路由：发往上海子网的数据包引流至杭州 WireGuard 网关 ECS
resource "alicloud_route_entry" "hangzhou_to_shanghai" {
  provider              = alicloud.hangzhou
  route_table_id        = alicloud_route_table.hangzhou.id
  destination_cidrblock = var.vswitch_cidr_shanghai
  nexthop_type          = "Instance"
  nexthop_id            = alicloud_instance.hangzhou.id
}

# 跨地域 VPC 路由：发往深圳子网的数据包引流至杭州 WireGuard 网关 ECS
resource "alicloud_route_entry" "hangzhou_to_shenzhen" {
  provider              = alicloud.hangzhou
  route_table_id        = alicloud_route_table.hangzhou.id
  destination_cidrblock = var.vswitch_cidr_shenzhen
  nexthop_type          = "Instance"
  nexthop_id            = alicloud_instance.hangzhou.id
}

# 将杭州 VSwitch 绑定至该自定义公共路由表
resource "alicloud_route_table_attachment" "hangzhou" {
  provider       = alicloud.hangzhou
  route_table_id = alicloud_route_table.hangzhou.id
  vswitch_id     = alicloud_vswitch.hangzhou.id
}

# 杭州安全组
resource "alicloud_security_group" "hangzhou" {
  provider            = alicloud.hangzhou
  vpc_id              = alicloud_vpc.hangzhou.id
  security_group_name = "${var.project_name}-sg-hangzhou"
  description         = "Managed by Terraform - Hangzhou Security Group (Allow All)"

  timeouts {
    delete = "30s"
  }
}

# 杭州安全组规则：入方向 IPv4 全放行
resource "alicloud_security_group_rule" "hangzhou_ingress_all" {
  provider          = alicloud.hangzhou
  type              = "ingress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.hangzhou.id
  cidr_ip           = "0.0.0.0/0"
}

# 杭州安全组规则：出方向 IPv4 全放行
resource "alicloud_security_group_rule" "hangzhou_egress_all" {
  provider          = alicloud.hangzhou
  type              = "egress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.hangzhou.id
  cidr_ip           = "0.0.0.0/0"
}

# 杭州安全组规则：入方向 IPv6 全放行
resource "alicloud_security_group_rule" "hangzhou_ingress_ipv6_all" {
  provider          = alicloud.hangzhou
  type              = "ingress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.hangzhou.id
  ipv6_cidr_ip      = "::/0"
}

# 杭州安全组规则：出方向 IPv6 全放行
resource "alicloud_security_group_rule" "hangzhou_egress_ipv6_all" {
  provider          = alicloud.hangzhou
  type              = "egress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.hangzhou.id
  ipv6_cidr_ip      = "::/0"
}

# 导入本地 SSH 公钥至杭州地域
resource "alicloud_key_pair" "hangzhou" {
  provider      = alicloud.hangzhou
  key_pair_name = "${var.project_name}-key-hangzhou"
  public_key    = var.ssh_public_key
  timeouts {
    delete = "30s"
  }
}

# 杭州 WireGuard 网关 ECS 实例 (分配 IPv6 + 节省停机模式 + ESSD Entry + 自动分配公网 IPv4)
resource "alicloud_instance" "hangzhou" {
  provider                   = alicloud.hangzhou
  instance_name              = "${var.project_name}-ecs-hangzhou"
  host_name                  = "fedora-hangzhou"
  vswitch_id                 = alicloud_vswitch.hangzhou.id
  security_groups            = [alicloud_security_group.hangzhou.id]
  image_id                   = data.alicloud_images.fedora_hangzhou.images[0].id
  instance_type              = var.instance_type
  instance_charge_type       = "PostPaid"
  spot_strategy              = var.spot_strategy
  spot_interruption_behavior = "Stop"
  system_disk_category       = var.system_disk_category
  system_disk_size           = var.system_disk_size
  internet_charge_type       = "PayByTraffic"
  internet_max_bandwidth_out = var.internet_max_bandwidth_out
  ipv6_address_count         = 1
  key_name                   = alicloud_key_pair.hangzhou.id
  description                = "Managed by Terraform - Hangzhou Spot Fedora ECS WireGuard Gateway"
  user_data = base64encode(<<-EOT
              #!/bin/bash
              curl -fsSL https://gitlab.com/liguanghui/ecs-metadata/-/raw/main/ecs-metadata -o /usr/local/bin/ecs-metadata
              chmod a+x /usr/local/bin/ecs-metadata
              EOT
  )
  depends_on = [
    alicloud_vpc_ipv6_gateway.hangzhou
  ]
}

# 查询杭州网关实例关联的 IPv6 地址 ID
data "alicloud_vpc_ipv6_addresses" "hangzhou" {
  provider               = alicloud.hangzhou
  associated_instance_id = alicloud_instance.hangzhou.id
  depends_on             = [alicloud_instance.hangzhou]
}

# 为杭州网关实例开通公网 IPv6 出网带宽 (按流量计费)
resource "alicloud_vpc_ipv6_internet_bandwidth" "hangzhou" {
  provider             = alicloud.hangzhou
  ipv6_address_id      = data.alicloud_vpc_ipv6_addresses.hangzhou.addresses[0].id
  ipv6_gateway_id      = alicloud_vpc_ipv6_gateway.hangzhou.ipv6_gateway_id
  bandwidth            = var.ipv6_internet_bandwidth
  internet_charge_type = "PayByTraffic"

  depends_on = [
    alicloud_instance.hangzhou
  ]
}



# ==============================================================================
# 2. 上海地域 (cn-shanghai)
# ==============================================================================

# 查询上海地域中同时支持指定规格、ESSD Entry系统盘与抢占式的实例类型及可用区列表
data "alicloud_instance_types" "shanghai" {
  provider             = alicloud.shanghai
  instance_type        = var.instance_type
  system_disk_category = var.system_disk_category
  instance_charge_type = "PostPaid"
  spot_strategy        = var.spot_strategy
}

# 动态查询上海最新官方 Fedora 镜像
data "alicloud_images" "fedora_shanghai" {
  provider    = alicloud.shanghai
  owners      = "system"
  name_regex  = "^fedora_[0-9]+_x64"
  most_recent = true
}

# 上海 VPC (开启 IPv6)
resource "alicloud_vpc" "shanghai" {
  provider    = alicloud.shanghai
  vpc_name    = "${var.project_name}-vpc-shanghai"
  cidr_block  = var.vpc_cidr_block
  enable_ipv6 = true
  description = "Managed by Terraform - Shanghai VPC (IPv6 Enabled)"
}

# 上海 VSwitch (交换机) - 开启 IPv6，创建在支持 ESSD Entry + 抢占式的可用区
resource "alicloud_vswitch" "shanghai" {
  provider             = alicloud.shanghai
  vswitch_name         = "${var.project_name}-vsw-shanghai"
  vpc_id               = alicloud_vpc.shanghai.id
  cidr_block           = var.vswitch_cidr_shanghai
  zone_id              = data.alicloud_instance_types.shanghai.instance_types[0].availability_zones[0]
  enable_ipv6          = true
  ipv6_cidr_block_mask = 20
  description          = "Managed by Terraform - Shanghai VSwitch (IPv6 Enabled)"
}

# 上海 IPv4 网关并激活（开启集中控制模式）
resource "alicloud_vpc_ipv4_gateway" "shanghai" {
  provider                 = alicloud.shanghai
  vpc_id                   = alicloud_vpc.shanghai.id
  ipv4_gateway_name        = "${var.project_name}-gw-shanghai"
  ipv4_gateway_description = "Managed by Terraform - Shanghai IPv4 Gateway (Centralized Mode)"
  enabled                  = true
  timeouts {
    delete = "30s"
  }
}

# 上海 IPv6 网关（开启公网 IPv6 通信底座）
resource "alicloud_vpc_ipv6_gateway" "shanghai" {
  provider          = alicloud.shanghai
  vpc_id            = alicloud_vpc.shanghai.id
  ipv6_gateway_name = "${var.project_name}-ipv6gw-shanghai"

  timeouts {
    delete = "30s"
  }
}

# 上海自定义公共路由表
resource "alicloud_route_table" "shanghai" {
  provider         = alicloud.shanghai
  vpc_id           = alicloud_vpc.shanghai.id
  route_table_name = "${var.project_name}-rtb-shanghai"
  associate_type   = "VSwitch"
  description      = "Managed by Terraform - Shanghai Custom Route Table"
}

# 在公共路由表中增加指向 IPv4 网关的默认公网路由
resource "alicloud_route_entry" "shanghai" {
  provider              = alicloud.shanghai
  route_table_id        = alicloud_route_table.shanghai.id
  destination_cidrblock = "0.0.0.0/0"
  nexthop_type          = "Ipv4Gateway"
  nexthop_id            = alicloud_vpc_ipv4_gateway.shanghai.id
}

# 在公共路由表中增加指向 IPv6 网关的默认公网路由
resource "alicloud_route_entry" "shanghai_ipv6_default" {
  provider              = alicloud.shanghai
  route_table_id        = alicloud_route_table.shanghai.id
  destination_cidrblock = "::/0"
  nexthop_type          = "IPv6Gateway"
  nexthop_id            = alicloud_vpc_ipv6_gateway.shanghai.ipv6_gateway_id
}

# 跨地域 VPC 路由：发往杭州子网的数据包引流至上海 WireGuard 网关 ECS
resource "alicloud_route_entry" "shanghai_to_hangzhou" {
  provider              = alicloud.shanghai
  route_table_id        = alicloud_route_table.shanghai.id
  destination_cidrblock = var.vswitch_cidr_hangzhou
  nexthop_type          = "Instance"
  nexthop_id            = alicloud_instance.shanghai.id
}

# 跨地域 VPC 路由：发往深圳子网的数据包引流至上海 WireGuard 网关 ECS
resource "alicloud_route_entry" "shanghai_to_shenzhen" {
  provider              = alicloud.shanghai
  route_table_id        = alicloud_route_table.shanghai.id
  destination_cidrblock = var.vswitch_cidr_shenzhen
  nexthop_type          = "Instance"
  nexthop_id            = alicloud_instance.shanghai.id
}

# 将上海 VSwitch 绑定至该自定义公共路由表
resource "alicloud_route_table_attachment" "shanghai" {
  provider       = alicloud.shanghai
  route_table_id = alicloud_route_table.shanghai.id
  vswitch_id     = alicloud_vswitch.shanghai.id
}

# 上海安全组
resource "alicloud_security_group" "shanghai" {
  provider            = alicloud.shanghai
  vpc_id              = alicloud_vpc.shanghai.id
  security_group_name = "${var.project_name}-sg-shanghai"
  description         = "Managed by Terraform - Shanghai Security Group (Allow All)"

  timeouts {
    delete = "30s"
  }
}

# 上海安全组规则：入方向 IPv4 全放行
resource "alicloud_security_group_rule" "shanghai_ingress_all" {
  provider          = alicloud.shanghai
  type              = "ingress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.shanghai.id
  cidr_ip           = "0.0.0.0/0"
}

# 上海安全组规则：出方向 IPv4 全放行
resource "alicloud_security_group_rule" "shanghai_egress_all" {
  provider          = alicloud.shanghai
  type              = "egress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.shanghai.id
  cidr_ip           = "0.0.0.0/0"
}

# 上海安全组规则：入方向 IPv6 全放行
resource "alicloud_security_group_rule" "shanghai_ingress_ipv6_all" {
  provider          = alicloud.shanghai
  type              = "ingress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.shanghai.id
  ipv6_cidr_ip      = "::/0"
}

# 上海安全组规则：出方向 IPv6 全放行
resource "alicloud_security_group_rule" "shanghai_egress_ipv6_all" {
  provider          = alicloud.shanghai
  type              = "egress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.shanghai.id
  ipv6_cidr_ip      = "::/0"
}

# 导入本地 SSH 公钥至上海地域
resource "alicloud_key_pair" "shanghai" {
  provider      = alicloud.shanghai
  key_pair_name = "${var.project_name}-key-shanghai"
  public_key    = var.ssh_public_key
  timeouts {
    delete = "30s"
  }
}

# 上海 WireGuard 网关 ECS 实例 (分配 IPv6 + 节省停机模式 + ESSD Entry + 自动分配公网 IPv4)
resource "alicloud_instance" "shanghai" {
  provider                   = alicloud.shanghai
  instance_name              = "${var.project_name}-ecs-shanghai"
  host_name                  = "fedora-shanghai"
  vswitch_id                 = alicloud_vswitch.shanghai.id
  security_groups            = [alicloud_security_group.shanghai.id]
  image_id                   = data.alicloud_images.fedora_shanghai.images[0].id
  instance_type              = var.instance_type
  instance_charge_type       = "PostPaid"
  spot_strategy              = var.spot_strategy
  spot_interruption_behavior = "Stop"
  system_disk_category       = var.system_disk_category
  system_disk_size           = var.system_disk_size
  internet_charge_type       = "PayByTraffic"
  internet_max_bandwidth_out = var.internet_max_bandwidth_out
  ipv6_address_count         = 1
  key_name                   = alicloud_key_pair.shanghai.id
  description                = "Managed by Terraform - Shanghai Spot Fedora ECS WireGuard Gateway"
  user_data = base64encode(<<-EOT
              #!/bin/bash
              curl -fsSL https://gitlab.com/liguanghui/ecs-metadata/-/raw/main/ecs-metadata -o /usr/local/bin/ecs-metadata
              chmod a+x /usr/local/bin/ecs-metadata
              EOT
  )
  depends_on = [
    alicloud_vpc_ipv6_gateway.shanghai
  ]
}

# 查询上海网关实例关联的 IPv6 地址 ID
data "alicloud_vpc_ipv6_addresses" "shanghai" {
  provider               = alicloud.shanghai
  associated_instance_id = alicloud_instance.shanghai.id
  depends_on             = [alicloud_instance.shanghai]
}

# 为上海网关实例开通公网 IPv6 出网带宽 (按流量计费)
resource "alicloud_vpc_ipv6_internet_bandwidth" "shanghai" {
  provider             = alicloud.shanghai
  ipv6_address_id      = data.alicloud_vpc_ipv6_addresses.shanghai.addresses[0].id
  ipv6_gateway_id      = alicloud_vpc_ipv6_gateway.shanghai.ipv6_gateway_id
  bandwidth            = var.ipv6_internet_bandwidth
  internet_charge_type = "PayByTraffic"

  depends_on = [
    alicloud_instance.shanghai
  ]
}



# ==============================================================================
# 3. 深圳地域 (cn-shenzhen)
# ==============================================================================

# 查询深圳地域中同时支持指定规格、ESSD Entry系统盘与抢占式的实例类型及可用区列表
data "alicloud_instance_types" "shenzhen" {
  provider             = alicloud.shenzhen
  instance_type        = var.instance_type
  system_disk_category = var.system_disk_category
  instance_charge_type = "PostPaid"
  spot_strategy        = var.spot_strategy
}

# 动态查询深圳最新官方 Fedora 镜像
data "alicloud_images" "fedora_shenzhen" {
  provider    = alicloud.shenzhen
  owners      = "system"
  name_regex  = "^fedora_[0-9]+_x64"
  most_recent = true
}

# 深圳 VPC (开启 IPv6)
resource "alicloud_vpc" "shenzhen" {
  provider    = alicloud.shenzhen
  vpc_name    = "${var.project_name}-vpc-shenzhen"
  cidr_block  = var.vpc_cidr_block
  enable_ipv6 = true
  description = "Managed by Terraform - Shenzhen VPC (IPv6 Enabled)"
}

# 深圳 VSwitch (交换机) - 开启 IPv6，创建在支持 ESSD Entry + 抢占式的可用区
resource "alicloud_vswitch" "shenzhen" {
  provider             = alicloud.shenzhen
  vswitch_name         = "${var.project_name}-vsw-shenzhen"
  vpc_id               = alicloud_vpc.shenzhen.id
  cidr_block           = var.vswitch_cidr_shenzhen
  zone_id              = data.alicloud_instance_types.shenzhen.instance_types[0].availability_zones[0]
  enable_ipv6          = true
  ipv6_cidr_block_mask = 30
  description          = "Managed by Terraform - Shenzhen VSwitch (IPv6 Enabled)"
}

# 深圳 IPv4 网关并激活（开启集中控制模式）
resource "alicloud_vpc_ipv4_gateway" "shenzhen" {
  provider                 = alicloud.shenzhen
  vpc_id                   = alicloud_vpc.shenzhen.id
  ipv4_gateway_name        = "${var.project_name}-gw-shenzhen"
  ipv4_gateway_description = "Managed by Terraform - Shenzhen IPv4 Gateway (Centralized Mode)"
  enabled                  = true
  timeouts {
    delete = "30s"
  }
}

# 深圳 IPv6 网关（开启公网 IPv6 通信底座）
resource "alicloud_vpc_ipv6_gateway" "shenzhen" {
  provider          = alicloud.shenzhen
  vpc_id            = alicloud_vpc.shenzhen.id
  ipv6_gateway_name = "${var.project_name}-ipv6gw-shenzhen"

  timeouts {
    delete = "30s"
  }
}

# 深圳自定义公共路由表
resource "alicloud_route_table" "shenzhen" {
  provider         = alicloud.shenzhen
  vpc_id           = alicloud_vpc.shenzhen.id
  route_table_name = "${var.project_name}-rtb-shenzhen"
  associate_type   = "VSwitch"
  description      = "Managed by Terraform - Shenzhen Custom Route Table"
}

# 在公共路由表中增加指向 IPv4 网关的默认公网路由
resource "alicloud_route_entry" "shenzhen" {
  provider              = alicloud.shenzhen
  route_table_id        = alicloud_route_table.shenzhen.id
  destination_cidrblock = "0.0.0.0/0"
  nexthop_type          = "Ipv4Gateway"
  nexthop_id            = alicloud_vpc_ipv4_gateway.shenzhen.id
}

# 在公共路由表中增加指向 IPv6 网关的默认公网路由
resource "alicloud_route_entry" "shenzhen_ipv6_default" {
  provider              = alicloud.shenzhen
  route_table_id        = alicloud_route_table.shenzhen.id
  destination_cidrblock = "::/0"
  nexthop_type          = "IPv6Gateway"
  nexthop_id            = alicloud_vpc_ipv6_gateway.shenzhen.ipv6_gateway_id
}

# 跨地域 VPC 路由：发往杭州子网的数据包引流至深圳 WireGuard 网关 ECS
resource "alicloud_route_entry" "shenzhen_to_hangzhou" {
  provider              = alicloud.shenzhen
  route_table_id        = alicloud_route_table.shenzhen.id
  destination_cidrblock = var.vswitch_cidr_hangzhou
  nexthop_type          = "Instance"
  nexthop_id            = alicloud_instance.shenzhen.id
}

# 跨地域 VPC 路由：发往上海子网的数据包引流至深圳 WireGuard 网关 ECS
resource "alicloud_route_entry" "shenzhen_to_shanghai" {
  provider              = alicloud.shenzhen
  route_table_id        = alicloud_route_table.shenzhen.id
  destination_cidrblock = var.vswitch_cidr_shanghai
  nexthop_type          = "Instance"
  nexthop_id            = alicloud_instance.shenzhen.id
}

# 将深圳 VSwitch 绑定至该自定义公共路由表
resource "alicloud_route_table_attachment" "shenzhen" {
  provider       = alicloud.shenzhen
  route_table_id = alicloud_route_table.shenzhen.id
  vswitch_id     = alicloud_vswitch.shenzhen.id
}

# 深圳安全组
resource "alicloud_security_group" "shenzhen" {
  provider            = alicloud.shenzhen
  vpc_id              = alicloud_vpc.shenzhen.id
  security_group_name = "${var.project_name}-sg-shenzhen"
  description         = "Managed by Terraform - Shenzhen Security Group (Allow All)"

  timeouts {
    delete = "30s"
  }
}

# 深圳安全组规则：入方向 IPv4 全放行
resource "alicloud_security_group_rule" "shenzhen_ingress_all" {
  provider          = alicloud.shenzhen
  type              = "ingress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.shenzhen.id
  cidr_ip           = "0.0.0.0/0"
}

# 深圳安全组规则：出方向 IPv4 全放行
resource "alicloud_security_group_rule" "shenzhen_egress_all" {
  provider          = alicloud.shenzhen
  type              = "egress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.shenzhen.id
  cidr_ip           = "0.0.0.0/0"
}

# 深圳安全组规则：入方向 IPv6 全放行
resource "alicloud_security_group_rule" "shenzhen_ingress_ipv6_all" {
  provider          = alicloud.shenzhen
  type              = "ingress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.shenzhen.id
  ipv6_cidr_ip      = "::/0"
}

# 深圳安全组规则：出方向 IPv6 全放行
resource "alicloud_security_group_rule" "shenzhen_egress_ipv6_all" {
  provider          = alicloud.shenzhen
  type              = "egress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.shenzhen.id
  ipv6_cidr_ip      = "::/0"
}

# 导入本地 SSH 公钥至深圳地域
resource "alicloud_key_pair" "shenzhen" {
  provider      = alicloud.shenzhen
  key_pair_name = "${var.project_name}-key-shenzhen"
  public_key    = var.ssh_public_key
  timeouts {
    delete = "30s"
  }
}

# 深圳 WireGuard 网关 ECS 实例 (分配 IPv6 + 节省停机模式 + ESSD Entry + 自动分配公网 IPv4)
resource "alicloud_instance" "shenzhen" {
  provider                   = alicloud.shenzhen
  instance_name              = "${var.project_name}-ecs-shenzhen"
  host_name                  = "fedora-shenzhen"
  vswitch_id                 = alicloud_vswitch.shenzhen.id
  security_groups            = [alicloud_security_group.shenzhen.id]
  image_id                   = data.alicloud_images.fedora_shenzhen.images[0].id
  instance_type              = var.instance_type
  instance_charge_type       = "PostPaid"
  spot_strategy              = var.spot_strategy
  spot_interruption_behavior = "Stop"
  system_disk_category       = var.system_disk_category
  system_disk_size           = var.system_disk_size
  internet_charge_type       = "PayByTraffic"
  internet_max_bandwidth_out = var.internet_max_bandwidth_out
  ipv6_address_count         = 1
  key_name                   = alicloud_key_pair.shenzhen.id
  description                = "Managed by Terraform - Shenzhen Spot Fedora ECS WireGuard Gateway"
  user_data = base64encode(<<-EOT
              #!/bin/bash
              curl -fsSL https://gitlab.com/liguanghui/ecs-metadata/-/raw/main/ecs-metadata -o /usr/local/bin/ecs-metadata
              chmod a+x /usr/local/bin/ecs-metadata
              EOT
  )
  depends_on = [
    alicloud_vpc_ipv6_gateway.shenzhen
  ]
}

# 查询深圳网关实例关联的 IPv6 地址 ID
data "alicloud_vpc_ipv6_addresses" "shenzhen" {
  provider               = alicloud.shenzhen
  associated_instance_id = alicloud_instance.shenzhen.id
  depends_on             = [alicloud_instance.shenzhen]
}

# 为深圳网关实例开通公网 IPv6 出网带宽 (按流量计费)
resource "alicloud_vpc_ipv6_internet_bandwidth" "shenzhen" {
  provider             = alicloud.shenzhen
  ipv6_address_id      = data.alicloud_vpc_ipv6_addresses.shenzhen.addresses[0].id
  ipv6_gateway_id      = alicloud_vpc_ipv6_gateway.shenzhen.ipv6_gateway_id
  bandwidth            = var.ipv6_internet_bandwidth
  internet_charge_type = "PayByTraffic"

  depends_on = [
    alicloud_instance.shenzhen
  ]
}


