# ==============================================================================
# 输出定义 (outputs.tf)
# ==============================================================================
# 在 Terraform 中，output 块用于在执行 `terraform apply` 成功后向终端打印关键信息，
# 也可以作为模块间传递数据或供其他外部系统查询的接口。
# ==============================================================================

# --- 杭州输出 ---

output "hangzhou_vpc_id" {
  description = "杭州 VPC ID"
  value       = alicloud_vpc.hangzhou.id
}

output "hangzhou_vswitch_id" {
  description = "杭州 VSwitch ID"
  value       = alicloud_vswitch.hangzhou.id
}

output "hangzhou_selected_zone" {
  description = "杭州 VSwitch / ECS 所在可用区"
  value       = alicloud_vswitch.hangzhou.zone_id
}

output "hangzhou_ipv4_gateway_id" {
  description = "杭州 IPv4 网关 ID (集中控制模式)"
  value       = alicloud_vpc_ipv4_gateway.hangzhou.id
}

output "hangzhou_route_table_id" {
  description = "杭州自定义公共路由表 ID"
  value       = alicloud_route_table.hangzhou.id
}

output "hangzhou_security_group_id" {
  description = "杭州全通安全组 ID"
  value       = alicloud_security_group.hangzhou.id
}

output "hangzhou_instance_id" {
  description = "杭州抢占式 Fedora ECS 实例 ID"
  value       = alicloud_instance.hangzhou.id
}

output "hangzhou_instance_private_ip" {
  description = "杭州 ECS 私网 IP"
  value       = alicloud_instance.hangzhou.primary_ip_address
}

output "hangzhou_instance_public_ip" {
  description = "杭州 ECS 自动分配的公网 IP"
  value       = alicloud_instance.hangzhou.public_ip
}

output "hangzhou_ssh_command" {
  description = "杭州 ECS SSH 快捷登录命令"
  value       = "ssh root@${alicloud_instance.hangzhou.public_ip}"
}

# --- 上海输出 ---

output "shanghai_vpc_id" {
  description = "上海 VPC ID"
  value       = alicloud_vpc.shanghai.id
}

output "shanghai_vswitch_id" {
  description = "上海 VSwitch ID"
  value       = alicloud_vswitch.shanghai.id
}

output "shanghai_selected_zone" {
  description = "上海 VSwitch / ECS 所在可用区"
  value       = alicloud_vswitch.shanghai.zone_id
}

output "shanghai_ipv4_gateway_id" {
  description = "上海 IPv4 网关 ID (集中控制模式)"
  value       = alicloud_vpc_ipv4_gateway.shanghai.id
}

output "shanghai_route_table_id" {
  description = "上海自定义公共路由表 ID"
  value       = alicloud_route_table.shanghai.id
}

output "shanghai_security_group_id" {
  description = "上海全通安全组 ID"
  value       = alicloud_security_group.shanghai.id
}

output "shanghai_instance_id" {
  description = "上海抢占式 Fedora ECS 实例 ID"
  value       = alicloud_instance.shanghai.id
}

output "shanghai_instance_private_ip" {
  description = "上海 ECS 私网 IP"
  value       = alicloud_instance.shanghai.primary_ip_address
}

output "shanghai_instance_public_ip" {
  description = "上海 ECS 自动分配的公网 IP"
  value       = alicloud_instance.shanghai.public_ip
}

output "shanghai_ssh_command" {
  description = "上海 ECS SSH 快捷登录命令"
  value       = "ssh root@${alicloud_instance.shanghai.public_ip}"
}

# --- 深圳输出 ---

output "shenzhen_vpc_id" {
  description = "深圳 VPC ID"
  value       = alicloud_vpc.shenzhen.id
}

output "shenzhen_vswitch_id" {
  description = "深圳 VSwitch ID"
  value       = alicloud_vswitch.shenzhen.id
}

output "shenzhen_selected_zone" {
  description = "深圳 VSwitch / ECS 所在可用区"
  value       = alicloud_vswitch.shenzhen.zone_id
}

output "shenzhen_ipv4_gateway_id" {
  description = "深圳 IPv4 网关 ID (集中控制模式)"
  value       = alicloud_vpc_ipv4_gateway.shenzhen.id
}

output "shenzhen_route_table_id" {
  description = "深圳自定义公共路由表 ID"
  value       = alicloud_route_table.shenzhen.id
}

output "shenzhen_security_group_id" {
  description = "深圳全通安全组 ID"
  value       = alicloud_security_group.shenzhen.id
}

output "shenzhen_instance_id" {
  description = "深圳抢占式 Fedora ECS 实例 ID"
  value       = alicloud_instance.shenzhen.id
}

output "shenzhen_instance_private_ip" {
  description = "深圳 ECS 私网 IP"
  value       = alicloud_instance.shenzhen.primary_ip_address
}

output "shenzhen_instance_public_ip" {
  description = "深圳 ECS 自动分配的公网 IP"
  value       = alicloud_instance.shenzhen.public_ip
}

output "shenzhen_ssh_command" {
  description = "深圳 ECS SSH 快捷登录命令"
  value       = "ssh root@${alicloud_instance.shenzhen.public_ip}"
}

# --- 聚合总览 ---

output "network_topology_summary" {
  description = "多地域网络与计算拓扑汇总概览"
  value = {
    hangzhou = {
      region          = var.region_hangzhou
      zone_id         = alicloud_vswitch.hangzhou.zone_id
      vpc_id          = alicloud_vpc.hangzhou.id
      vpc_cidr        = alicloud_vpc.hangzhou.cidr_block
      vswitch_id      = alicloud_vswitch.hangzhou.id
      vswitch_cidr    = alicloud_vswitch.hangzhou.cidr_block
      ipv4_gateway_id = alicloud_vpc_ipv4_gateway.hangzhou.id
      route_table_id  = alicloud_route_table.hangzhou.id
      security_group  = alicloud_security_group.hangzhou.id
      instance_id     = alicloud_instance.hangzhou.id
      private_ip      = alicloud_instance.hangzhou.primary_ip_address
      public_ip       = alicloud_instance.hangzhou.public_ip
      ssh_command     = "ssh root@${alicloud_instance.hangzhou.public_ip}"
    }
    shanghai = {
      region          = var.region_shanghai
      zone_id         = alicloud_vswitch.shanghai.zone_id
      vpc_id          = alicloud_vpc.shanghai.id
      vpc_cidr        = alicloud_vpc.shanghai.cidr_block
      vswitch_id      = alicloud_vswitch.shanghai.id
      vswitch_cidr    = alicloud_vswitch.shanghai.cidr_block
      ipv4_gateway_id = alicloud_vpc_ipv4_gateway.shanghai.id
      route_table_id  = alicloud_route_table.shanghai.id
      security_group  = alicloud_security_group.shanghai.id
      instance_id     = alicloud_instance.shanghai.id
      private_ip      = alicloud_instance.shanghai.primary_ip_address
      public_ip       = alicloud_instance.shanghai.public_ip
      ssh_command     = "ssh root@${alicloud_instance.shanghai.public_ip}"
    }
    shenzhen = {
      region          = var.region_shenzhen
      zone_id         = alicloud_vswitch.shenzhen.zone_id
      vpc_id          = alicloud_vpc.shenzhen.id
      vpc_cidr        = alicloud_vpc.shenzhen.cidr_block
      vswitch_id      = alicloud_vswitch.shenzhen.id
      vswitch_cidr    = alicloud_vswitch.shenzhen.cidr_block
      ipv4_gateway_id = alicloud_vpc_ipv4_gateway.shenzhen.id
      route_table_id  = alicloud_route_table.shenzhen.id
      security_group  = alicloud_security_group.shenzhen.id
      instance_id     = alicloud_instance.shenzhen.id
      private_ip      = alicloud_instance.shenzhen.primary_ip_address
      public_ip       = alicloud_instance.shenzhen.public_ip
      ssh_command     = "ssh root@${alicloud_instance.shenzhen.public_ip}"
    }
  }
}
