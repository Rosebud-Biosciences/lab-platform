# Plan-only against mocked providers: what the preview group may do outside
# its namespaces, and the admission policy that holds it to its prefix.

mock_provider "kubernetes" {}
mock_provider "kubectl" {}

run "namespaces_and_nodepools_fenced_by_prefix" {
  command = plan

  assert {
    condition = anytrue([
      for r in kubernetes_cluster_role_v1.this.rule : contains(r.resources, "namespaces") && contains(r.verbs, "create") && contains(r.verbs, "delete")
    ])
    error_message = "a preview creates and deletes its own namespaces"
  }
  assert {
    condition = anytrue([for r in kubernetes_cluster_role_v1.this.rule : contains(r.resources, "nodepools")]) && anytrue([
      for r in kubernetes_cluster_role_v1.this.rule : contains(r.resources, "ec2nodeclasses")
    ])
    error_message = "with Karpenter, a preview manages its own NodePools and EC2NodeClasses"
  }
  assert {
    condition = alltrue([
      for r in kubernetes_cluster_role_v1.this.rule : !anytrue([for v in r.verbs : contains(["create", "update", "patch", "delete", "escalate", "*"], v)])
      if !anytrue([for res in r.resources : contains(["namespaces", "nodepools", "ec2nodeclasses", "rolebindings"], res)])
    ])
    error_message = "everything else cluster-wide is read-only, and nothing may escalate"
  }
  assert {
    condition = alltrue([
      for r in kubernetes_cluster_role_v1.this.rule : toset(r.verbs) == toset(["create", "get"]) if contains(r.resources, "rolebindings")
    ])
    error_message = "cluster-wide, RoleBindings may only be created (the policy fences where) and read back"
  }
  assert {
    condition = alltrue([
      for r in kubernetes_cluster_role_v1.this.rule : toset(r.verbs) == toset(["bind"]) && toset(r.resource_names) == toset(["preview-deployer-namespace-admin"]) if contains(r.resources, "clusterroles")
    ])
    error_message = "the preview may bind the namespace-admin ClusterRole and no other"
  }
  assert {
    condition     = kubernetes_cluster_role_v1.namespace_admin.metadata[0].name == "preview-deployer-namespace-admin" && output.namespace_admin_cluster_role == "preview-deployer-namespace-admin"
    error_message = "the namespace-admin ClusterRole is <name>-namespace-admin, published for modules/workloads"
  }
  assert {
    condition     = kubernetes_cluster_role_binding_v1.this.role_ref[0].name == "preview-deployer"
    error_message = "the only cluster-wide binding is the fenced ClusterRole's, never namespace-admin's"
  }
  assert {
    condition     = strcontains(kubectl_manifest.admission_policy.yaml_body, "rolebindings") && strcontains(kubectl_manifest.admission_policy.yaml_body, "request.namespace.startsWith(\\\"preview-\\\")")
    error_message = "the policy keeps the preview's RoleBindings to preview namespaces"
  }
  assert {
    condition     = strcontains(kubectl_manifest.admission_policy.yaml_body, "object.metadata.name.startsWith(\\\"preview-\\\")") && strcontains(kubectl_manifest.admission_policy.yaml_body, "oldObject.metadata.name.startsWith(\\\"preview-\\\")")
    error_message = "the policy checks the new and the old name against the prefix"
  }
  assert {
    condition     = strcontains(kubectl_manifest.admission_policy.yaml_body, "g == \\\"lab-platform:preview\\\"")
    error_message = "the policy restricts the preview group only"
  }
  assert {
    condition     = strcontains(kubectl_manifest.admission_policy.yaml_body, "nodepools") && strcontains(kubectl_manifest.admission_policy.yaml_body, "DELETE")
    error_message = "NodePools and deletes are fenced too"
  }
  assert {
    condition     = length(kubernetes_role_v1.dex) == 0
    error_message = "no grant in Dex's namespace unless asked"
  }
}

run "without_karpenter_and_with_dex" {
  command = plan

  variables {
    karpenter     = false
    dex_namespace = "dex"
  }

  assert {
    condition     = !anytrue([for r in kubernetes_cluster_role_v1.this.rule : contains(r.resources, "nodepools")]) && !strcontains(kubectl_manifest.admission_policy.yaml_body, "nodepools")
    error_message = "no NodePool grant or rule without Karpenter"
  }
  assert {
    condition     = kubernetes_role_v1.dex[0].metadata[0].namespace == "dex" && contains(kubernetes_role_v1.dex[0].rule[0].resources, "oauth2clients")
    error_message = "the preview group registers OAuth2Clients in Dex's namespace"
  }
}

run "prefix_must_end_in_a_dash" {
  command = plan

  variables {
    namespace_prefix = "pr"
  }

  expect_failures = [var.namespace_prefix]
}
