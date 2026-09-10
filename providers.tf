# ==============================================================================
# Provider 别名 (Alias) 配置
# ==============================================================================
# 在 Terraform 中，一个 Provider 块通常只对应云厂商的一个地域（Region）。
# 当我们需要在单个工程中跨多个地域部署资源时，必须使用 alias（别名）定义多个 Provider 实例。
# 在后续资源（Resource）或数据源（Data Source）中，通过 `provider = alicloud.<别名>` 进行显式绑定。
#
# 认证方式提示：
# 推荐使用环境变量注入 AccessKey 与 SecretKey，避免硬编码：
#   export ALICLOUD_ACCESS_KEY="LTAI..."
#   export ALICLOUD_SECRET_KEY="xxxx..."
# ==============================================================================

# 默认 Provider（默认为杭州）
provider "alicloud" {
  region = var.region_hangzhou
}

# 杭州 Provider 别名
provider "alicloud" {
  alias  = "hangzhou"
  region = var.region_hangzhou
}

# 上海 Provider 别名
provider "alicloud" {
  alias  = "shanghai"
  region = var.region_shanghai
}

# 深圳 Provider 别名
provider "alicloud" {
  alias  = "shenzhen"
  region = var.region_shenzhen
}
