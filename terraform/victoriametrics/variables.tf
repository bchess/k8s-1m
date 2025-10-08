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

variable "zone_id" {
  type = string
}

variable "cloud_infra" {
  type = any
}

variable "ca_cert" {
  type = object({
    cert_pem        = string
    private_key_pem = string
  })
}
