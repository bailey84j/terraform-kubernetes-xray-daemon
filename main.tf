resource "kubernetes_service_account" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = var.create_iam_role ? aws_iam_role.this[0].arn : var.iam_role_arn
    }
    labels = {
      "app.kubernetes.io/name"       = var.name
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "kubernetes_cluster_role" "this" {
  metadata {
    name = var.name
  }

  rule {
    verbs          = ["get"]
    api_groups     = [""]
    resources      = ["configmaps"]
    resource_names = ["cluster-info"]
  }
}

resource "kubernetes_daemonset" "this" {
  metadata {
    name      = "${var.name}-daemon"
    namespace = var.namespace
  }

  spec {
    selector {
      match_labels = {
        app = "${var.name}-daemon"
      }
    }

    template {
      metadata {
        labels = {
          app = "${var.name}-daemon"
        }
      }

      spec {
        volume {
          name = "config-volume"

          config_map {
            name = "xray-config"
          }
        }

        container {
          name    = "${var.name}-daemon"
          image   = "amazon/${var.image_name}:${var.image_version}"
          command = ["/usr/bin/xray", "-c", "/aws/xray/config.yaml"]

          port {
            name           = "${var.name}-ingest"
            host_port      = 2000
            container_port = 2000
            protocol       = "UDP"
          }

          port {
            name           = "${var.name}-tcp"
            host_port      = 2000
            container_port = 2000
            protocol       = "TCP"
          }

          resources {
            limits = {
              cpu = "512m"

              memory = "64Mi"
            }

            requests = {
              cpu = "256m"

              memory = "32Mi"
            }
          }

          volume_mount {
            name       = "config-volume"
            read_only  = true
            mount_path = "/aws/xray"
          }
        }

        service_account_name = "${var.name}"
      }
    }

    strategy {
      type = "RollingUpdate"
    }
  }
}

resource "kubernetes_config_map" "this" {
  metadata {
    name      = "xray-config"
    namespace = var.namespace
  }

  data = {
    "config.yaml" = "TotalBufferSizeMB: 24\nSocket:\n  UDPAddress: \"0.0.0.0:2000\"\n  TCPAddress: \"0.0.0.0:2000\"\nVersion: 2"
  }
}

resource "kubernetes_service" "this" {
  metadata {
    name      = "${var.name}-service"
    namespace = var.namespace
  }

  spec {
    port {
      name     = "${var.name}-ingest"
      protocol = "UDP"
      port     = 2000
    }

    port {
      name     = "${var.name}-tcp"
      protocol = "TCP"
      port     = 2000
    }

    selector = {
      app = "${var.name}-daemon"
    }

    cluster_ip = "None"
  }
}

// region aws iam role

locals {
  iam_role_name     = coalesce(var.iam_role_name, "${var.eks_cluster_name}-${var.name}")
}
// to be updated
data "aws_iam_policy_document" "assume_role_policy" {
  count = var.create_iam_role ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.target.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values = [
        "system:serviceaccount:${var.namespace}:${var.name}"
      ]
    }
    principals {
      identifiers = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(data.aws_eks_cluster.target.identity[0].oidc[0].issuer, "https://", "")}"
      ]
      type = "Federated"
    }
  }
}

resource "aws_iam_role" "this" {
  count = var.create_iam_role ? 1 : 0

  name        = var.iam_role_use_name_prefix ? null : local.iam_role_name
  name_prefix = var.iam_role_use_name_prefix ? "${local.iam_role_name}${var.prefix_separator}" : null
  path        = var.iam_role_path
  description = var.iam_role_description

  assume_role_policy    = data.aws_iam_policy_document.assume_role_policy[0].json
  permissions_boundary  = var.iam_role_permissions_boundary
  force_detach_policies = true

  managed_policy_arns = ["arn:${data.aws_partition.current.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"]

  tags = merge(var.tags, var.iam_role_tags)
  
}

// endregion aws iam role