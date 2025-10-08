variable "ipv4gateway" {
  type = object({
    hostname = string
    password = string
  })
}

variable "replicas" {
  type    = number
  default = 3
}

variable "zone_id" {
  type = string
}

variable "ssh_key_url" {
  type = string
}

variable "separate_etcd" {
  type    = bool
  default = false
}

variable "victoriametrics_password" {
  type    = string
  default = "password"
}

variable "cloud_details" {
  type = any
}

variable "etcd_cloud_details" {
  type = any
}

variable "cloud_infra" {
  type = any
}

variable "kube_scheduler_cloud_details" {
  type        = any
  description = "If set, a dedicated kube-scheduler will be deployed"
}
