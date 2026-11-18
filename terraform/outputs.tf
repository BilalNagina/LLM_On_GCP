output "cluster_name" {
  value = google_container_cluster.llm.name
}

output "cluster_endpoint" {
  value = google_container_cluster.llm.endpoint
}

output "cluster_ca" {
  value     = google_container_cluster.llm.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "registry" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.llm.repository_id}"
}

output "models_bucket" {
  value = google_storage_bucket.models.name
}

output "mirror_sa" {
  value = google_service_account.mirror.email
}
