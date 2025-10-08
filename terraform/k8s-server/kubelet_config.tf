data "remote_file" "k3s_kubelet_config" {
  conn {
    host        = "[${module.k3s_server_first.ipv6_addresses[0]}]"
    user        = "root"
    private_key = tls_private_key.k3s_server_first.private_key_openssh
    timeout     = 300
  }
  path = "/etc/rancher/k3s/k3s.yaml"

  depends_on = [
    null_resource.wait_for_apiserver
  ]
}

resource "null_resource" "wait_for_apiserver" {
  depends_on = [
    aws_route53_record.apiserver_each_first,
    module.k3s_server_first[0].id
  ]

  provisioner "local-exec" {
    command = <<EOT
    until curl --connect-timeout 10 -s -o /dev/null -k -w %%{http_code} https://[${module.k3s_server_first.ipv6_addresses[0]}]:6443 | grep -q "401"; do
      echo "Waiting for API server..."
      sleep 5
    done
    echo "API server is up!"
    EOT
  }
}
