terraform {
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "2.21.0"
    }
    remote = {
      source  = "tenstad/remote"
      version = "0.1.3"
    }
  }
}
