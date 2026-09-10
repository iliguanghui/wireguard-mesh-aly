# ==============================================================================
# 核心资源编排 (main.tf)
# ==============================================================================
# 本工程实现阿里云多地域自动化编排：
# 1. 动态实例与可用区查询 (data.alicloud_instance_types):
#    原生精准匹配：规格 (instance_type) + ESSD Entry (system_disk_category) + 抢占式 (spot_strategy)，
#    提取输出的 availability_zones[0] 作为交换机创建位置，杜绝传统 data.alicloud_zones 对新磁盘支持不全的问题。
# 2. 动态镜像查询 (data.alicloud_images): 自动拉取官方最新 Fedora x86_64 镜像。
# 3. 专有网络与子网 (alicloud_vpc / alicloud_vswitch)。
# 4. 安全出入控制 (alicloud_vpc_ipv4_gateway 集中控制 + alicloud_route_table 自定义公共路由表)。
# 5. 全通安全组 (alicloud_security_group / alicloud_security_group_rule): 放通一切进出协议。
# 6. 本地 SSH 密钥导入 (alicloud_key_pair): 导入本地 /Users/admin/.ssh/id_rsa.pub。
# 7. 抢占式极低成本 ECS (alicloud_instance):
#    - 抢占式自动出价: SpotAsPriceGo
#    - 中断模式: 节省停机 (spot_interruption_behavior = "Stop")
#    - 系统盘: 20GB ESSD Entry (cloud_essd_entry)
#    - 公网 IP: 系统自动分配 + 按流量计费 (PayByTraffic)
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

# 杭州 VPC (专有网络)
resource "alicloud_vpc" "hangzhou" {
  provider    = alicloud.hangzhou
  vpc_name    = "${var.project_name}-vpc-hangzhou"
  cidr_block  = var.vpc_cidr_block
  description = "Managed by Terraform - Hangzhou VPC"
}

# 杭州 VSwitch (交换机) - 创建在支持 ESSD Entry + 抢占式的可用区
resource "alicloud_vswitch" "hangzhou" {
  provider     = alicloud.hangzhou
  vswitch_name = "${var.project_name}-vsw-hangzhou"
  vpc_id       = alicloud_vpc.hangzhou.id
  cidr_block   = var.vswitch_cidr_hangzhou
  zone_id      = data.alicloud_instance_types.hangzhou.instance_types[0].availability_zones[0]
  description  = "Managed by Terraform - Hangzhou VSwitch"
}

# 杭州 IPv4 网关并激活（开启集中控制模式）
resource "alicloud_vpc_ipv4_gateway" "hangzhou" {
  provider                 = alicloud.hangzhou
  vpc_id                   = alicloud_vpc.hangzhou.id
  ipv4_gateway_name        = "${var.project_name}-gw-hangzhou"
  ipv4_gateway_description = "Managed by Terraform - Hangzhou IPv4 Gateway (Centralized Mode)"
  enabled                  = true
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
}

# 杭州安全组规则：入方向全放行
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

# 杭州安全组规则：出方向全放行
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

# 导入本地 SSH 公钥至杭州地域
resource "alicloud_key_pair" "hangzhou" {
  provider      = alicloud.hangzhou
  key_pair_name = "${var.project_name}-key-hangzhou"
  public_key    = var.ssh_public_key
}

# 杭州 Fedora 抢占式 ECS 实例 (节省停机模式 + ESSD Entry + 自动分配公网 IP)
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
  key_name                   = alicloud_key_pair.hangzhou.id
  description                = "Managed by Terraform - Hangzhou Spot Fedora ECS (Spot Interruption Stop Mode)"
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

# 上海 VPC
resource "alicloud_vpc" "shanghai" {
  provider    = alicloud.shanghai
  vpc_name    = "${var.project_name}-vpc-shanghai"
  cidr_block  = var.vpc_cidr_block
  description = "Managed by Terraform - Shanghai VPC"
}

# 上海 VSwitch - 创建在支持 ESSD Entry + 抢占式的可用区
resource "alicloud_vswitch" "shanghai" {
  provider     = alicloud.shanghai
  vswitch_name = "${var.project_name}-vsw-shanghai"
  vpc_id       = alicloud_vpc.shanghai.id
  cidr_block   = var.vswitch_cidr_shanghai
  zone_id      = data.alicloud_instance_types.shanghai.instance_types[0].availability_zones[0]
  description  = "Managed by Terraform - Shanghai VSwitch"
}

# 上海 IPv4 网关并激活（开启集中控制模式）
resource "alicloud_vpc_ipv4_gateway" "shanghai" {
  provider                 = alicloud.shanghai
  vpc_id                   = alicloud_vpc.shanghai.id
  ipv4_gateway_name        = "${var.project_name}-gw-shanghai"
  ipv4_gateway_description = "Managed by Terraform - Shanghai IPv4 Gateway (Centralized Mode)"
  enabled                  = true
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
}

# 上海安全组规则：入方向全放行
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

# 上海安全组规则：出方向全放行
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

# 导入本地 SSH 公钥至上海地域
resource "alicloud_key_pair" "shanghai" {
  provider      = alicloud.shanghai
  key_pair_name = "${var.project_name}-key-shanghai"
  public_key    = var.ssh_public_key
}

# 上海 Fedora 抢占式 ECS 实例 (节省停机模式 + ESSD Entry + 自动分配公网 IP)
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
  key_name                   = alicloud_key_pair.shanghai.id
  description                = "Managed by Terraform - Shanghai Spot Fedora ECS (Spot Interruption Stop Mode)"
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

# 深圳 VPC
resource "alicloud_vpc" "shenzhen" {
  provider    = alicloud.shenzhen
  vpc_name    = "${var.project_name}-vpc-shenzhen"
  cidr_block  = var.vpc_cidr_block
  description = "Managed by Terraform - Shenzhen VPC"
}

# 深圳 VSwitch - 创建在支持 ESSD Entry + 抢占式的可用区
resource "alicloud_vswitch" "shenzhen" {
  provider     = alicloud.shenzhen
  vswitch_name = "${var.project_name}-vsw-shenzhen"
  vpc_id       = alicloud_vpc.shenzhen.id
  cidr_block   = var.vswitch_cidr_shenzhen
  zone_id      = data.alicloud_instance_types.shenzhen.instance_types[0].availability_zones[0]
  description  = "Managed by Terraform - Shenzhen VSwitch"
}

# 深圳 IPv4 网关并激活（开启集中控制模式）
resource "alicloud_vpc_ipv4_gateway" "shenzhen" {
  provider                 = alicloud.shenzhen
  vpc_id                   = alicloud_vpc.shenzhen.id
  ipv4_gateway_name        = "${var.project_name}-gw-shenzhen"
  ipv4_gateway_description = "Managed by Terraform - Shenzhen IPv4 Gateway (Centralized Mode)"
  enabled                  = true
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
}

# 深圳安全组规则：入方向全放行
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

# 深圳安全组规则：出方向全放行
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

# 导入本地 SSH 公钥至深圳地域
resource "alicloud_key_pair" "shenzhen" {
  provider      = alicloud.shenzhen
  key_pair_name = "${var.project_name}-key-shenzhen"
  public_key    = var.ssh_public_key
}

# 深圳 Fedora 抢占式 ECS 实例 (节省停机模式 + ESSD Entry + 自动分配公网 IP)
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
  key_name                   = alicloud_key_pair.shenzhen.id
  description                = "Managed by Terraform - Shenzhen Spot Fedora ECS (Spot Interruption Stop Mode)"
}
