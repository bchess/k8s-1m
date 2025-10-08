variable "apiserver_hostname" {
  type = string
}

variable "node_selector" {
  type        = map(string)
  description = "Selector for which nodes the pod can run on"
}

variable "k3s_token" {
  type      = string
  sensitive = true
}

variable "replicas" {
  type    = number
  default = 1
}

variable "namespace" {
  type    = string
  default = "default"
}

variable "pull_secret_name" {
  type = string
}
