variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "apiserver_cloud_details" {
  type = any
  default = {
    vultr = {
      plan   = "vc2-1c-1gb"
      region = "ewr"
    }
  }
}

variable "apiserver_replicas" {
  type    = number
  default = 1
}

variable "domain" {
  type = string
}

variable "github_user" {
  type = string
}

variable "kubelet_details" {
  type = list(object({
    replicas = number
    pin_cpus = optional(bool, true)
    vultr = optional(object({
      plan   = string
      region = string
    }))
    aws = optional(object({
      availability_zone = string
      instance_type     = string
      disk_size_gb      = optional(number)
      spot_price        = optional(number)
      min_vcpu          = optional(number)
      min_memory_mib    = optional(number)
    }))
    gcp = optional(object({
      zone          = string
      instance_type = string
      disk_size_gb  = optional(number)
      preemptible   = optional(bool, false)
    }))
  }))
  default = []
}

variable "kubelet_pod_replicas" {
  type    = number
  default = 0
}

variable "separate_etcd" {
  type    = bool
  default = true
}

variable "etcd_cloud_details" {
  type = any
  default = {
    vultr = {
      plan   = "vc2-1c-1gb"
      region = "ewr"
    }
  }
}

variable "victoriametrics_cloud_details" {
  type = any
  default = {
    vultr = {
      plan   = "vc2-1c-1gb"
      region = "ewr"
    }
  }
}

variable "ipv4_gateway_vultr_region" {
  type    = string
  default = "ewr"
}

variable "google_credentials" {
  type = string
}

variable "google_project" {
  type = string
}

variable "dist_scheduler" {
  type = object({
    replicas       = number
    parallelism    = optional(number, 1)
    num_schedulers = optional(number, 15)
    cores          = optional(number, 15)
    gogc           = optional(number, 1000)
    watch_pods     = optional(bool, false)
  })
  default = {
    replicas = 1
  }
}

variable "kube_scheduler_cloud_details" {
  type    = any
  default = null
}

variable "deploy_parca" {
  type    = bool
  default = true
}

variable "deploy_fluentbit" {
  type    = bool
  default = true
}
