variable "replicas" {
  type    = number
  default = 1
}

variable "offset" {
  type        = number
  description = "In names that include the index, add this offset"
  default     = 0
}

variable "unique_name" {
  type = string
}

variable "firewall_inbound_rules" {
  type    = list(string)
  default = []
}

variable "startup_script" {
  type = string
}

variable "tags" {
  type    = list(string)
  default = []
}

variable "cloud_details" {
  type = object({
    vultr = optional(object({
      plan   = string
      region = string
    }))
    aws = optional(object({
      instance_type     = string
      availability_zone = string
      disk_size_gb      = optional(number)
      spot_price        = optional(number)
      min_vcpu          = optional(number)
      min_memory_mib    = optional(number)
    }))
    gcp = optional(object({
      instance_type     = string
      zone              = string
      disk_size_gb      = optional(number)
      preemptible       = optional(bool, false)
      tier_1_networking = optional(bool, false)
    }))
  })
}

variable "cloud_infra" {
  type = object({
    aws = object({
      vpc_id       = string
      subnet_ids   = map(string)
      ipv6_profile = string
    })
    gcp = object({
      vpc_id     = string
      subnet_ids = map(string)
    })
  })
}
