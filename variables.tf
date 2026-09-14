variable "project_name" {
  type        = string
  description = "项目标识前缀，用于为资源命名"
  default     = "mesh"
}

# --- 地域配置 ---

variable "region_hangzhou" {
  type        = string
  description = "杭州地域代码"
  default     = "cn-hangzhou"
}

variable "region_shanghai" {
  type        = string
  description = "上海地域代码"
  default     = "cn-shanghai"
}

variable "region_shenzhen" {
  type        = string
  description = "深圳地域代码"
  default     = "cn-shenzhen"
}

# --- VPC 网段配置 ---

variable "vpc_cidr_block" {
  type        = string
  description = "所有地域 VPC 统一使用的网段 (按需求为 192.168.0.0/16)"
  default     = "192.168.0.0/16"
}

# --- 子网 (VSwitch) 网段配置 ---

variable "vswitch_cidr_hangzhou" {
  type        = string
  description = "杭州子网 (VSwitch) 网段"
  default     = "192.168.10.0/24"
}

variable "vswitch_cidr_shanghai" {
  type        = string
  description = "上海子网 (VSwitch) 网段"
  default     = "192.168.20.0/24"
}

variable "vswitch_cidr_shenzhen" {
  type        = string
  description = "深圳子网 (VSwitch) 网段"
  default     = "192.168.30.0/24"
}

# --- ECS 计算与计费配置 ---

variable "ssh_public_key" {
  type        = string
  description = "本机 SSH 公钥文件内容"
  default     = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC1CiuDboXSHyl+Ms0YKskqYyHF8b25k+mHzZ+OoT0tWkHuep/PDO4bKOh5Q97MTudkhLn3wrErE+NPPcFXuqaoX0aUwt+GvF2vMqbuoJ2nrN2fBs4UpROQnWhykXjeNZWbPvDEB/lQ7LCha0IY87FwAaauQya2wt1nttbzsTmw/gSsk2zB0qpE+YphtuYND3xO3pT7JaCiHnJlYaLl7mpzvPT2KXAJu2MBILF+fN+fmL7P16YSHfbUAcUR54jDRYXV+QUw3xVVD/1o4tmnFiDUmQ3qu49cVDrZvKILdDWTQ0afL+348euZigkUlRTgcvteFDWqzXN9mAuG74CuzV7Gv0dq5BodnfwLK4oH/mFVrXUr6Kx0FrJiNMmPW0qXc9FBDgJayJP+0349i8oe3gdX1lErw4BQ3k2NC4Zdyp87AnOurddEnCdgAPWGHjXvJQonEbYvcnOgkNRMXpXhQ3UoNmEHkRU40v6ImXLm7dd0aKn40voKAxiykb850KMlmEM= lgh@raycloud.com"
}

variable "instance_type" {
  type        = string
  description = "ECS 实例规格代码，默认使用高性价比经济型规格"
  default     = "ecs.e-c1m1.large"
}

variable "spot_strategy" {
  type        = string
  description = "抢占式竞价策略：SpotAsPriceGo (自动按市场价竞价以获取最高折扣)"
  default     = "SpotAsPriceGo"
}

variable "system_disk_category" {
  type        = string
  description = "系统盘类型：使用最经济的 ESSD Entry (cloud_essd_entry)"
  default     = "cloud_essd_entry"
}

variable "system_disk_size" {
  type        = number
  description = "系统盘容量 (GiB)，Linux 官方镜像支持的最小容量为 20"
  default     = 20
}

variable "internet_max_bandwidth_out" {
  type        = number
  description = "系统自动分配公网 IP 的出网带宽上限 (Mbps)，按流量计费"
  default     = 5
}

# --- IPv6 与测试实例配置 ---

variable "ipv6_internet_bandwidth" {
  type        = number
  description = "WireGuard 网关 ECS 实例分配的公网 IPv6 出网带宽上限 (Mbps)，按流量计费"
  default     = 5
}

variable "test_instance_count" {
  type        = number
  description = "每个地域子网内创建的测试 ECS 实例数量（不分配 IPv6，用于验证跨地域透明 IPv4 互通）"
  default     = 1
}
