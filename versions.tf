terraform {
  cloud {
    organization = "my-terraform-playground"
    workspaces {
      name = "wireguard-mesh-aly"
    }
  }
  required_version = ">= 1.0.0"

  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 1.220"
    }
  }
}
