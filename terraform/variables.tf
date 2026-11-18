variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "authorized_cidr" {
  description = "CIDR allowed to reach the GKE control plane (your workstation's public IP /32)"
  type        = string
}
