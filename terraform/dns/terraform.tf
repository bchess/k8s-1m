terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "domain" {
  description = "The domain name to create the zone for"
}
