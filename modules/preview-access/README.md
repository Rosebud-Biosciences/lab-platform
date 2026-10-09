# preview-access

What a preview's deploy identity may do outside its own namespaces, and
nothing more. A preview runs a pull request's workflow, so whoever can push a
branch controls that identity; this keeps it off everything that is not the
preview's.

- Outside the preview's namespaces, this module's ClusterRole lets it create,
  change and delete namespaces and (with `karpenter`) NodePools and
  EC2NodeClasses, and read the cluster-scoped kinds the providers look up.
  RBAC cannot restrict a create or delete by name, so a
  ValidatingAdmissionPolicy holds the group to names starting with
  `namespace_prefix`, checking the new and the old object.
- Inside them it is an admin through RBAC: in each namespace it creates, it
  binds the `namespace_admin_cluster_role` ClusterRole to `group` first
  ([`modules/workloads`](../workloads)' `namespace_admin`). The ClusterRole
  lets it create RoleBindings and bind that one role, and the admission
  policy keeps those RoleBindings to `namespace_prefix` namespaces. On EKS,
  map the identity's access entry to `group` and give it no access policy:
  `AmazonEKSAdminPolicy` covers no custom resources, and the API server lets
  nobody create a Role granting more than they hold through RBAC, which every
  chart a preview installs does.
- With `dex_namespace`, it may register OAuth2Clients there;
  [`modules/dex`](../dex)'s `client_admission` fences their ids.

Every namespace a preview creates must start with `namespace_prefix`
([`modules/workloads`](../workloads)' and
[`aws/compute-adapter`](../../aws/compute-adapter)'s `name_prefix`), and no
other namespace may: keep production and platform namespaces off it. On EKS,
[`aws/eks-platform`](../../aws/eks-platform)'s `preview_access` installs this
module. Needs Kubernetes >= 1.30 (ValidatingAdmissionPolicy).

```hcl
module "preview_access" {
  source = "github.com/Rosebud-Biosciences/lab-platform//modules/preview-access?ref=v0.2.0"

  dex_namespace = "dex"
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.12.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | >= 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | >= 2.12.1 |

## Resources

| Name | Type |
|------|------|
| [kubectl_manifest.admission_binding](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.admission_policy](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_cluster_role_binding_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_binding_v1) | resource |
| [kubernetes_cluster_role_v1.namespace_admin](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_v1) | resource |
| [kubernetes_cluster_role_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_v1) | resource |
| [kubernetes_role_binding_v1.dex](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role_binding_v1) | resource |
| [kubernetes_role_v1.dex](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_dex_namespace"></a> [dex\_namespace](#input\_dex\_namespace) | Dex's namespace, where a preview registers its OAuth2Clients (modules/workloads auth = oidc); modules/dex's client\_admission fences their ids. Empty grants nothing there. | `string` | `""` | no |
| <a name="input_group"></a> [group](#input\_group) | Kubernetes group the preview deploy identity is mapped to (on EKS, its access entry's kubernetes\_groups) | `string` | `"lab-platform:preview"` | no |
| <a name="input_karpenter"></a> [karpenter](#input\_karpenter) | Let previews manage their own Karpenter NodePools and EC2NodeClasses (aws/compute-adapter) | `bool` | `true` | no |
| <a name="input_name"></a> [name](#input\_name) | Name of the ClusterRole, its binding, the dex Role and the admission policy; the namespace-admin ClusterRole is <name>-namespace-admin | `string` | `"preview-deployer"` | no |
| <a name="input_namespace_prefix"></a> [namespace\_prefix](#input\_namespace\_prefix) | Prefix of every cluster-scoped name a preview creates -- its namespaces, NodePools and EC2NodeClasses (modules/workloads' and aws/compute-adapter's name\_prefix starts with it). No other namespace may start with it: the preview may bind itself admin in any namespace that does. | `string` | `"preview-"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_cluster_role_name"></a> [cluster\_role\_name](#output\_cluster\_role\_name) | The ClusterRole bound to group |
| <a name="output_group"></a> [group](#output\_group) | Kubernetes group to map the preview deploy identity to (an EKS access entry's kubernetes\_groups) |
| <a name="output_namespace_admin_cluster_role"></a> [namespace\_admin\_cluster\_role](#output\_namespace\_admin\_cluster\_role) | The ClusterRole a preview binds to group in each namespace it creates (modules/workloads namespace\_admin.cluster\_role) |
<!-- END_TF_DOCS -->
