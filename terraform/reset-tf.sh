#!/bin/bash
terraform state list | grep '\(module.kubernetes\|module.kubelet_pod\|kubernetes_namespace_v1.kubelet\)' | xargs -d'\n' terraform state rm
terraform state rm 'module.k8s_server[0].null_resource.wait_for_apiserver'
