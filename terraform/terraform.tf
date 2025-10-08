terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    google = {
      source = "hashicorp/google"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    vultr = {
      source = "vultr/vultr"
    }
    remote = {
      source  = "tenstad/remote"
      version = "0.1.3"
    }
  }
}

variable "vultr_api_key" {
  type      = string
  sensitive = true
}

variable "aws_access_key" {
  type      = string
  sensitive = true
}

variable "aws_secret_key" {
  type      = string
  sensitive = true
}

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

provider "vultr" {
  api_key = var.vultr_api_key
}

provider "google" {
  credentials = var.google_credentials
  project     = var.google_project
}
