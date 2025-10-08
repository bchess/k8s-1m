terraform {
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "2.21.0"
    }
    cloudflare = {
      source = "cloudflare/cloudflare"
    }
  }
}

variable "region" {
  type    = string
  default = "ewr"
}

variable "zone_id" {
  type = string
}

variable "hostname" {
  type    = string
  default = "ipv4gateway"
}

variable "ssh_key_url" {
  type = string
}
