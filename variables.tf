locals {
  name           = var.cluster_name
  region         = var.region
  dns_names_yaml = yamldecode(jsonencode(var.dns_names))
}

variable "cluster_name" {
  type        = string
  description = "Cluster Name"
}

variable "project_name" {
  type        = string
  description = "Project Name"
}

variable "region" {
  type        = string
  description = "Project Region"
}

variable "email" {
  type        = string
  description = "your email"
}

variable "openai_api" {
  type = string
}

variable "dns_names" {
  type = list(string)
  default = [
    "elasticsearch.silveiratecnologia.com",
    "kibana.silveiratecnologia.com",
    "jupyter.silveiratecnologia.com",
    "locust.silveiratecnologia.com",
    "app.silveiratecnologia.com"
  ]
  description = "Use the DNS to be configured in the Ingress for each one of the deployed services. For this, use your own domain."
}