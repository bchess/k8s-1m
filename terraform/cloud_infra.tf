module "aws_vpc" {
  count  = local.has_any_aws ? 1 : 0
  source = "./modules/aws_vpc"
}

module "gcp_vpc" {
  count   = local.has_any_gcp ? 1 : 0
  source  = "./modules/gcp_vpc"
  regions = ["us-east1", "us-east4", "us-east5", "us-west1", "us-west2", "us-central1", "us-south1"]
}

locals {
  cloud_infra = {
    aws = one(module.aws_vpc[*].infra)
    gcp = one(module.gcp_vpc[*].infra)
  }

  has_any_aws = anytrue(flatten([
    [lookup(var.apiserver_cloud_details, "aws", null) != null],
    [for cloud in var.kubelet_details : cloud.replicas > 0 && lookup(cloud, "aws", null) != null],
    [lookup(var.etcd_cloud_details, "aws", null) != null],
    [lookup(var.victoriametrics_cloud_details, "aws", null) != null],
  ]))
  has_any_gcp = anytrue(flatten([
    [lookup(var.apiserver_cloud_details, "gcp", null) != null],
    [for cloud in var.kubelet_details : cloud.replicas > 0 && lookup(cloud, "gcp", null) != null],
    [lookup(var.etcd_cloud_details, "gcp", null) != null],
    [lookup(var.victoriametrics_cloud_details, "gcp", null) != null],
  ]))
}


#  has_any_aws = anytrue(flatten([
#    [for cloud in var.apiserver_cloud_details : cloud.aws != null],
#    [for cloud in var.kubelet_details : cloud.aws != null],
#    [for cloud in var.etcd_cloud_details : cloud.aws != null],
#    [for cloud in var.victoriametrics_cloud_details : cloud.aws != null],
#  ]))
#
