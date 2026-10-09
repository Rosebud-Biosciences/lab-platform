# ------------------------------------------------------------------------------
# A preview's deploy identity may create what every preview creates outside
# its namespaces -- the namespaces themselves and, with Karpenter, its
# NodePools and EC2NodeClasses -- and look up what the providers read. Inside
# each namespace it makes, it binds the namespace-admin ClusterRole to its
# group (modules/workloads namespace_admin) before anything else goes there,
# and from then on owns that namespace through RBAC. It must be RBAC: the API
# server lets nobody create a Role granting more than they hold through RBAC,
# and the charts a preview installs create Roles over pods and custom
# resources. (EKS access policies count for neither: AmazonEKSAdminPolicy
# covers no custom resources, and grants are not RBAC.)
#
# RBAC cannot restrict create or delete by name or by namespace, so the
# admission policy below does: from this group, namespaces, NodePools and
# EC2NodeClasses only by names starting with namespace_prefix (checking the
# new and the old object, so nothing is renamed into or out of reach), and
# RoleBindings only inside such namespaces.
# ------------------------------------------------------------------------------

locals {
  verbs          = ["get", "list", "watch", "create", "update", "patch", "delete"]
  prefix         = jsonencode(var.namespace_prefix)
  operations     = ["CREATE", "UPDATE", "DELETE"]
  namespace_role = "${var.name}-namespace-admin"

  admitted_kinds = concat(
    [
      { apiGroups = [""], apiVersions = ["v1"], operations = local.operations, resources = ["namespaces"] },
      { apiGroups = ["rbac.authorization.k8s.io"], apiVersions = ["v1"], operations = local.operations, resources = ["rolebindings"] },
    ],
    var.karpenter ? [
      { apiGroups = ["karpenter.sh"], apiVersions = ["*"], operations = local.operations, resources = ["nodepools"] },
      { apiGroups = ["karpenter.k8s.aws"], apiVersions = ["*"], operations = local.operations, resources = ["ec2nodeclasses"] },
    ] : [],
  )
}

# Everything, but only where a RoleBinding grants it: a preview's own
# namespaces. Bound cluster-wide it would be cluster-admin; nothing here does.
resource "kubernetes_cluster_role_v1" "namespace_admin" {
  #checkov:skip=CKV_K8S_49:Admin of a preview's own namespaces, bound only by RoleBindings the admission policy keeps to them; listing kinds would break on every chart's next Role.
  metadata {
    name = local.namespace_role
  }

  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["*"]
  }
}

resource "kubernetes_cluster_role_v1" "this" {
  metadata {
    name = var.name
  }

  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = local.verbs
  }

  dynamic "rule" {
    for_each = var.karpenter ? { "karpenter.sh" = "nodepools", "karpenter.k8s.aws" = "ec2nodeclasses" } : {}
    content {
      api_groups = [rule.key]
      resources  = [rule.value]
      verbs      = local.verbs
    }
  }

  # The first binding in a new namespace, before the preview holds anything
  # there: create (the admission policy keeps it to preview namespaces), get
  # (the provider reads it straight back), and bind on the namespace-admin
  # ClusterRole alone.
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["rolebindings"]
    verbs      = ["create", "get"]
  }
  rule {
    api_groups     = ["rbac.authorization.k8s.io"]
    resources      = ["clusterroles"]
    resource_names = [local.namespace_role]
    verbs          = ["bind"]
  }

  # What the kubernetes, helm and kubectl providers look up while planning a
  # preview's releases and manifests.
  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingressclasses"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["scheduling.k8s.io"]
    resources  = ["priorityclasses"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "this" {
  metadata {
    name = var.name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.this.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = var.group
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "kubernetes_role_v1" "dex" {
  count = var.dex_namespace == "" ? 0 : 1

  metadata {
    name      = var.name
    namespace = var.dex_namespace
  }

  rule {
    api_groups = ["dex.coreos.com"]
    resources  = ["oauth2clients"]
    verbs      = local.verbs
  }
}

resource "kubernetes_role_binding_v1" "dex" {
  count = var.dex_namespace == "" ? 0 : 1

  metadata {
    name      = var.name
    namespace = var.dex_namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.dex[0].metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = var.group
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "kubectl_manifest" "admission_policy" {
  yaml_body = yamlencode({
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicy"
    metadata   = { name = var.name }
    spec = {
      failurePolicy    = "Fail"
      matchConstraints = { resourceRules = local.admitted_kinds }
      variables = [
        { name = "preview", expression = "request.userInfo.groups.exists(g, g == ${jsonencode(var.group)})" },
        { name = "binding", expression = "request.resource.resource == 'rolebindings'" },
      ]
      validations = [
        {
          expression        = "!variables.preview || variables.binding || ((object == null || object.metadata.name.startsWith(${local.prefix})) && (oldObject == null || oldObject.metadata.name.startsWith(${local.prefix})))"
          messageExpression = "'a preview may only create, change or delete ' + request.resource.resource + ' named ' + ${local.prefix} + '*'"
          reason            = "Forbidden"
        },
        {
          expression        = "!variables.preview || !variables.binding || request.namespace.startsWith(${local.prefix})"
          messageExpression = "'a preview may only bind roles in namespaces named ' + ${local.prefix} + '*'"
          reason            = "Forbidden"
        },
      ]
    }
  })
}

resource "kubectl_manifest" "admission_binding" {
  yaml_body = yamlencode({
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicyBinding"
    metadata   = { name = var.name }
    spec = {
      policyName        = var.name
      validationActions = ["Deny"]
    }
  })

  depends_on = [kubectl_manifest.admission_policy]
}
