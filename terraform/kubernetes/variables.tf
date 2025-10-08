variable "monitoring_hostname" {
  type        = string
  description = "The monitoring hostname"
}

variable "monitoring_auth" {
  type = object({
    username = string
    password = string
  })
}

variable "ca_crt" {
  type = string
}

variable "dist_scheduler" {
  type = object({
    replicas       = number
    watch_pods     = optional(bool, false)
    parallelism    = optional(number, 1)
    num_schedulers = optional(number, 15)
    cores          = optional(number, 15)
    gogc           = optional(number, 1000)
  })
}

variable "pull_secret_namespaces" {
  type    = list(string)
  default = []
}

variable "deploy_parca" {
  type    = bool
  default = true
}

variable "deploy_fluentbit" {
  type    = bool
  default = true
}

variable "service_cidr" {
  type = string
}

variable "domain" {
  type        = string
  description = "The domain name for the AWS Route53 zone"
}
