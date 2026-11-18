terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "this" {}

locals {
  wi_pool = "${var.project_id}.svc.id.goog"
  # Kubernetes ServiceAccount llm/llm-server, referenced directly as an IAM principal
  # (Workload Identity Federation for GKE, no Google service account needed).
  llm_ksa_principal = "principal://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${local.wi_pool}/subject/ns/llm/sa/llm-server"
}

# ---------------------------------------------------------------- network ---
resource "google_compute_network" "vpc" {
  name                    = "llm-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "gke" {
  name                     = "gke-nodes"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.10.0.0/20"
  private_ip_google_access = true # private nodes reach Artifact Registry / GCS without internet

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }
}

# Deliberately NO Cloud Router / Cloud NAT: nodes have private IPs only and
# no route to the internet. Every image and model is imported into
# Artifact Registry / GCS first.

# ------------------------------------------------------ service accounts ---
resource "google_service_account" "nodes" {
  account_id   = "gke-nodes"
  display_name = "GKE node service account (least privilege)"
}

resource "google_project_iam_member" "nodes_default" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_service_account" "mirror" {
  account_id   = "image-mirror"
  display_name = "Cloud Build: imports images and model files"
}

resource "google_project_iam_member" "mirror_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.mirror.email}"
}

# --------------------------------------------------------- registry/bucket ---
resource "google_artifact_registry_repository" "llm" {
  location      = var.region
  repository_id = "llm"
  format        = "DOCKER"
  description   = "Mirrored serving and load-test images"
}

resource "google_artifact_registry_repository_iam_member" "nodes_read" {
  location   = google_artifact_registry_repository.llm.location
  repository = google_artifact_registry_repository.llm.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_artifact_registry_repository_iam_member" "mirror_write" {
  location   = google_artifact_registry_repository.llm.location
  repository = google_artifact_registry_repository.llm.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.mirror.email}"
}

resource "google_storage_bucket" "models" {
  name                        = "${var.project_id}-models"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
  versioning {
    enabled = true
  }
}

resource "google_storage_bucket_iam_member" "llm_read_models" {
  bucket = google_storage_bucket.models.name
  role   = "roles/storage.objectViewer"
  member = local.llm_ksa_principal

  # The <project>.svc.id.goog identity pool only exists once a cluster with
  # Workload Identity is created; binding before that fails with
  # "Identity Pool does not exist".
  depends_on = [google_container_cluster.llm]
}

resource "google_storage_bucket_iam_member" "mirror_write_models" {
  bucket = google_storage_bucket.models.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.mirror.email}"
}

# ---------------------------------------------------------------- cluster ---
resource "google_container_cluster" "llm" {
  name     = "llm-cluster"
  location = var.zone # zonal: covered by the GKE free-tier management credit

  network         = google_compute_network.vpc.id
  subnetwork      = google_compute_subnetwork.gke.id
  networking_mode = "VPC_NATIVE"

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false

  node_config {
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  release_channel {
    channel = "REGULAR"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.authorized_cidr
      display_name = "admin-workstation"
    }
  }

  workload_identity_config {
    workload_pool = local.wi_pool
  }

  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  addons_config {
    gcs_fuse_csi_driver_config {
      enabled = true
    }
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  cost_management_config {
    enabled = true
  }

  # node_config only describes the temporary default pool, which is removed
  # right away. Without this, the provider sees drift on the next plan and
  # REPLACES the whole cluster (happened once during the build).
  lifecycle {
    ignore_changes = [node_config]
  }

  depends_on = [google_project_iam_member.nodes_default]
}

resource "google_container_node_pool" "cpu" {
  name     = "cpu-inference"
  cluster  = google_container_cluster.llm.id
  location = var.zone

  autoscaling {
    min_node_count = 1
    max_node_count = 4
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type    = "e2-standard-4"
    spot            = true
    disk_size_gb    = 50
    disk_type       = "pd-balanced"
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      workload = "llm-cpu"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}
