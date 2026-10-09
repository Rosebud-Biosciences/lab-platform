# ------------------------------------------------------------------------------
# NAMESPACE ADMIN: for a deployer that holds nothing in a namespace until it
# binds itself there (modules/preview-access), the binding goes into each
# namespace this module creates before anything else does.
# ------------------------------------------------------------------------------

locals {
  created_namespaces = merge(
    { for ns in kubernetes_namespace_v1.webapp : "webapp" => ns.metadata[0].name },
    { for ns in kubernetes_namespace_v1.dagster : "dagster" => ns.metadata[0].name },
    { for ns in kubernetes_namespace_v1.mlflow : "mlflow" => ns.metadata[0].name },
    { for ns in kubernetes_namespace_v1.ray : "ray" => ns.metadata[0].name },
    { for ns in kubernetes_namespace_v1.argo : "argo" => ns.metadata[0].name },
    { for ns in kubernetes_namespace_v1.jupyterhub : "jupyterhub" => ns.metadata[0].name },
  )

  # A namespace this module does not create keeps its bare name.
  namespace = {
    for k, name in local.namespace_names : k => try(
      kubernetes_role_binding_v1.namespace_admin[k].metadata[0].namespace,
      local.created_namespaces[k],
      name,
    )
  }
}

resource "kubernetes_role_binding_v1" "namespace_admin" {
  for_each = var.namespace_admin == null ? {} : local.created_namespaces

  metadata {
    name      = "namespace-admin"
    namespace = each.value
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = var.namespace_admin.cluster_role
  }

  subject {
    kind      = "Group"
    name      = var.namespace_admin.group
    api_group = "rbac.authorization.k8s.io"
  }
}
