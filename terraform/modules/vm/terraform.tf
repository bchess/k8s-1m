terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    null = {
      source = "hashicorp/null"
    }
    google = {
      source = "hashicorp/google"
    }
    vultr = {
      source = "vultr/vultr"
    }
  }
}
