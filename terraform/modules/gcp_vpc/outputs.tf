output "infra" {
  value = {
    "vpc_id"     = google_compute_network.self.id
    "subnet_ids" = { for k, v in google_compute_subnetwork.self : k => v.id }
  }
  depends_on = [google_compute_network.self, google_compute_subnetwork.self]
}
