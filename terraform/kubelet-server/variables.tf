variable "ipv4gateway" {
  type = object({
    hostname = string
    password = string
  })
}

variable "cloud_details" {
  type = any
}

variable "ssh_key_url" {
  type = string
}

variable "apiserver_hostname" {
  type = string
}

variable "k3s_token" {
  type      = string
  sensitive = true
}

variable "replicas" {
  type    = number
  default = 1
}

variable "offset" {
  type        = number
  default     = 0
  description = "The offset to use for the DNS records"
}

variable "zone_id" {
  type    = string
  default = ""
}

variable "pin_cpus" {
  type    = bool
  default = true
}

variable "cloud_infra" {
  type = any
}

variable "victoriametrics_password" {
  type = string
}

variable "extra_labels" {
  type    = map(string)
  default = {}
}
