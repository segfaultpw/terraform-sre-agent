/**
 * Read-only Kubernetes access for SRE Agent.
 *
 * A ServiceAccount, a ClusterRole limited to the resources the product reads,
 * and a token to paste into the Kubernetes connector.
 */

locals {
  # Exactly what the Kubernetes connector and the capacity analyzer request.
  # `get` and `list` only: the client can issue writes, but no code path does,
  # so granting them would be latent authority nobody uses.
  core_resources  = ["pods", "nodes", "namespaces", "services"]
  apps_resources  = ["deployments", "replicasets"]
  batch_resources = ["jobs", "cronjobs"]
}

resource "kubernetes_service_account_v1" "this" {
  metadata {
    name      = var.service_account_name
    namespace = var.namespace
    labels    = var.labels
  }
}

resource "kubernetes_cluster_role_v1" "this" {
  metadata {
    name   = var.cluster_role_name
    labels = var.labels
  }

  rule {
    api_groups = [""]
    resources  = local.core_resources
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = ["apps"]
    resources  = local.apps_resources
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = ["batch"]
    resources  = local.batch_resources
    verbs      = ["get", "list"]
  }

  # Utilization. Without metrics-server installed these calls fail and the
  # capacity page reports requests without usage, which reads as "nothing is
  # over-provisioned" rather than as missing data, so it is worth checking.
  dynamic "rule" {
    for_each = var.enable_metrics ? [1] : []

    content {
      api_groups = ["metrics.k8s.io"]
      resources  = ["pods", "nodes"]
      verbs      = ["get", "list"]
    }
  }

  # Events are the single most useful thing during an investigation (OOMKills,
  # failed scheduling, image pull errors) but they can carry application detail
  # in their messages, so they are separately controllable.
  dynamic "rule" {
    for_each = var.enable_events ? [1] : []

    content {
      api_groups = [""]
      resources  = ["events"]
      verbs      = ["get", "list"]
    }
  }
}

resource "kubernetes_cluster_role_binding_v1" "this" {
  metadata {
    name   = var.cluster_role_binding_name
    labels = var.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.this.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.this.metadata[0].name
    namespace = kubernetes_service_account_v1.this.metadata[0].namespace
  }
}

# Kubernetes 1.24+ stopped minting ServiceAccount token Secrets automatically,
# so a long-lived token has to be requested explicitly. It is long-lived by
# design: SRE Agent connects from outside the cluster and cannot refresh a
# projected volume token.
#
# Prefer create_token = false and supply a short-lived token from your own
# rotation if you have one; this exists because most people do not.
resource "kubernetes_secret_v1" "token" {
  count = var.create_token ? 1 : 0

  metadata {
    name      = "${var.service_account_name}-token"
    namespace = var.namespace
    labels    = var.labels

    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.this.metadata[0].name
    }
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}
