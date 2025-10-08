terraform {
  required_providers {
    htpasswd = {
      source  = "loafoe/htpasswd"
      version = "1.2.1"
    }
    vultr = {
      source  = "vultr/vultr"
      version = "2.21.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "4.0.5"
    }
  }
}
