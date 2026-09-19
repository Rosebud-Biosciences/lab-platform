# ------------------------------------------------------------------------------
# Who may touch which OAuth2Client (var.client_admission)
#
# Per-environment clients are CRs in Dex's namespace, so whoever can write
# there can rewrite any environment's redirect URIs -- including prod's, from
# a preview's CI. This policy narrows the restricted principals (the preview
# role) to clients whose id carries a preview prefix, on create, update and
# delete, checking both the new and the old object so a prod client cannot be
# renamed into, or out of, reach. The prod deployer is not restricted.
# ------------------------------------------------------------------------------

locals {
  client_admission_restricted = var.client_admission == null ? "false" : join(" || ", compact([
    length(var.client_admission.restricted_user_prefixes) > 0 ? "${jsonencode(var.client_admission.restricted_user_prefixes)}.exists(p, request.userInfo.username.startsWith(p))" : "",
    length(var.client_admission.restricted_groups) > 0 ? "request.userInfo.groups.exists(g, g in ${jsonencode(var.client_admission.restricted_groups)})" : "",
  ]))
  client_admission_pattern = var.client_admission == null ? "" : jsonencode(var.client_admission.allowed_id_pattern)
}

resource "kubectl_manifest" "client_admission_policy" {
  count = var.client_admission == null ? 0 : 1

  yaml_body = yamlencode({
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicy"
    metadata   = { name = "${var.release_name}-client-ownership" }
    spec = {
      failurePolicy = "Fail"
      matchConstraints = {
        resourceRules = [{
          apiGroups   = ["dex.coreos.com"]
          apiVersions = ["*"]
          operations  = ["CREATE", "UPDATE", "DELETE"]
          resources   = ["oauth2clients"]
        }]
      }
      variables = [{ name = "restricted", expression = local.client_admission_restricted }]
      validations = [{
        expression        = "!variables.restricted || ((object == null || string(object.id).matches(${local.client_admission_pattern})) && (oldObject == null || string(oldObject.id).matches(${local.client_admission_pattern})))"
        messageExpression = "'this identity may only manage OAuth2Clients whose id matches ' + ${local.client_admission_pattern}"
        reason            = "Forbidden"
      }]
    }
  })

  depends_on = [helm_release.dex]
}

resource "kubectl_manifest" "client_admission_binding" {
  count = var.client_admission == null ? 0 : 1

  yaml_body = yamlencode({
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicyBinding"
    metadata   = { name = "${var.release_name}-client-ownership" }
    spec = {
      policyName        = "${var.release_name}-client-ownership"
      validationActions = ["Deny"]
      matchResources = {
        namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = local.namespace } }
      }
    }
  })

  depends_on = [kubectl_manifest.client_admission_policy]
}
