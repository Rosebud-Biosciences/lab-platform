# ------------------------------------------------------------------------------
# The preview deploy identity, scoped to its own namespaces (modules/preview-
# access). Its access entry (var.access_entries, the caller's) maps it to
# preview_access.group and nothing else; this grants what it may create, held
# to "<namespace_prefix>" by an admission policy, including the binding that
# makes it admin of each namespace it creates.
# ------------------------------------------------------------------------------

module "preview_access" {
  count  = var.preview_access == null ? 0 : 1
  source = "../../modules/preview-access"

  group            = var.preview_access.group
  namespace_prefix = var.preview_access.namespace_prefix
  karpenter        = var.enable_karpenter
  dex_namespace    = var.preview_access.dex_namespace

  depends_on = [module.eks_blueprints_addons_core]
}
