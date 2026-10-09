# Plan-only against mocked providers: the rendered chart values must carry
# Dex's config exactly as a relying party will depend on it (issuer, kubernetes
# storage for dynamic clients, the login paths), and the ingress/namespace
# toggles must do what they say.

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}

run "password_db_for_ci" {
  command = plan

  variables {
    issuer_url         = "http://dex.dex.svc.cluster.local:5556/dex"
    enable_password_db = true
    static_passwords = [{
      email    = "admin@example.com"
      hash     = "$2a$10$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W"
      username = "admin"
      user_id  = "08a8684b-db88-4b73-90a9-3cd1661f5466"
    }]
    connectors = [{ type = "mockCallback", id = "mock", name = "Example" }]
  }

  assert {
    condition     = helm_release.dex.namespace == "dex" && helm_release.dex.chart == "dex"
    error_message = "the release must land in the dex namespace"
  }
  assert {
    condition     = strcontains(nonsensitive(helm_release.dex.values[0]), "\"issuer\": \"http://dex.dex.svc.cluster.local:5556/dex\"")
    error_message = "issuer_url must be rendered verbatim into Dex's config"
  }
  assert {
    condition     = strcontains(nonsensitive(helm_release.dex.values[0]), "\"type\": \"kubernetes\"") && strcontains(nonsensitive(helm_release.dex.values[0]), "\"inCluster\": true")
    error_message = "storage must be the kubernetes backend so environments can register OAuth2Client CRs"
  }
  assert {
    condition     = strcontains(nonsensitive(helm_release.dex.values[0]), "\"enablePasswordDB\": true") && strcontains(nonsensitive(helm_release.dex.values[0]), "\"userID\": \"08a8684b-db88-4b73-90a9-3cd1661f5466\"")
    error_message = "static passwords must render with Dex's field names (userID)"
  }
  assert {
    condition     = strcontains(nonsensitive(helm_release.dex.values[0]), "\"type\": \"mockCallback\"")
    error_message = "connectors must be passed through to Dex's config"
  }
  assert {
    condition     = strcontains(nonsensitive(helm_release.dex.values[0]), "\"fullnameOverride\": \"dex\"") && !strcontains(nonsensitive(helm_release.dex.values[0]), "\"hosts\":")
    error_message = "no ingress by default; the Service name is pinned to the release name"
  }
  assert {
    condition     = output.in_cluster_url == "http://dex.dex.svc.cluster.local:5556" && output.namespace == "dex"
    error_message = "in-cluster URL must be derived from the release name and namespace"
  }
}

run "connector_only_with_ingress" {
  command = plan

  variables {
    issuer_url       = "https://dex.example.com/dex"
    namespace        = "identity"
    create_namespace = false
    release_name     = "idp"
    connectors = [{
      type   = "google"
      id     = "google"
      name   = "Google"
      config = { clientID = "id", clientSecret = "secret", redirectURI = "https://dex.example.com/dex/callback" }
    }]
    static_clients = [{ id = "kubectl", name = "kubectl", public = true, redirect_uris = ["http://localhost:8000"] }]
    ingress = {
      enabled         = true
      class_name      = "nginx"
      host            = "dex.example.com"
      annotations     = { "cert-manager.io/cluster-issuer" = "letsencrypt" }
      tls_secret_name = "dex-tls"
    }
  }

  assert {
    condition     = helm_release.dex.namespace == "identity" && output.service_name == "idp"
    error_message = "an existing namespace and a custom release name must be honoured"
  }
  assert {
    condition     = strcontains(nonsensitive(helm_release.dex.values[0]), "\"enablePasswordDB\": false")
    error_message = "the password DB stays off unless asked for"
  }
  assert {
    condition     = strcontains(nonsensitive(helm_release.dex.values[0]), "\"className\": \"nginx\"") && strcontains(nonsensitive(helm_release.dex.values[0]), "\"secretName\": \"dex-tls\"") && strcontains(nonsensitive(helm_release.dex.values[0]), "cert-manager.io/cluster-issuer")
    error_message = "the ingress must carry class, TLS secret and annotations"
  }
  assert {
    condition     = strcontains(nonsensitive(helm_release.dex.values[0]), "\"public\": true") && !strcontains(nonsensitive(helm_release.dex.values[0]), "\"secret\": \"\"")
    error_message = "a public static client renders without a secret"
  }
  assert {
    condition     = output.in_cluster_url == "http://idp.identity.svc.cluster.local:5556"
    error_message = "in-cluster URL must follow the custom names"
  }
}

run "no_login_path_is_refused" {
  command = plan

  variables {
    issuer_url = "http://dex.dex.svc.cluster.local:5556/dex"
  }

  expect_failures = [helm_release.dex]
}

run "connector_secrets_come_from_the_environment" {
  command = plan

  variables {
    issuer_url = "https://dex.example.com/dex"
    connectors = [{
      type   = "github"
      id     = "github"
      name   = "GitHub"
      config = { clientID = "$GITHUB_CLIENT_ID", clientSecret = "$GITHUB_CLIENT_SECRET", orgs = [{ name = "lab" }] }
    }]
    connector_env = { GITHUB_CLIENT_ID = "id", GITHUB_CLIENT_SECRET = "very-secret" }
  }

  assert {
    condition     = kubernetes_secret_v1.connector_env[0].metadata[0].name == "dex-connector-env" && strcontains(nonsensitive(helm_release.dex.values[0]), "\"secretRef\":")
    error_message = "connector_env becomes a Secret the Dex pod reads through envFrom"
  }
  assert {
    condition     = !strcontains(nonsensitive(helm_release.dex.values[0]), "very-secret") && strcontains(nonsensitive(helm_release.dex.values[0]), "$GITHUB_CLIENT_SECRET")
    error_message = "the secret value never reaches the Helm values; the config carries only the $VAR reference"
  }
  assert {
    condition     = strcontains(nonsensitive(helm_release.dex.values[0]), "\"idTokens\": \"1h\"")
    error_message = "ID tokens default to one hour so relying parties re-validate often"
  }
}

run "connector_secrets_from_an_existing_secret" {
  command = plan

  variables {
    issuer_url                = "https://dex.example.com/dex"
    connectors                = [{ type = "mockCallback", id = "mock", name = "mock" }]
    connector_env_secret_name = "dex-upstream-credentials"
  }

  assert {
    condition     = length(kubernetes_secret_v1.connector_env) == 0 && strcontains(nonsensitive(helm_release.dex.values[0]), "dex-upstream-credentials")
    error_message = "an existing Secret is referenced, not created (its values stay out of state)"
  }
}

run "client_admission_policy" {
  command = plan

  variables {
    issuer_url = "https://dex.example.com/dex"
    connectors = [{ type = "mockCallback", id = "mock", name = "mock" }]
    client_admission = {
      restricted_user_prefixes = ["arn:aws:sts::123456789012:assumed-role/preview-deployer/"]
      restricted_groups        = ["previews"]
    }
  }

  assert {
    condition     = strcontains(kubectl_manifest.client_admission_policy[0].yaml_body, "request.userInfo.username.startsWith(p)") && strcontains(kubectl_manifest.client_admission_policy[0].yaml_body, "preview-deployer") && strcontains(kubectl_manifest.client_admission_policy[0].yaml_body, "g in [\\\"previews\\\"]")
    error_message = "restricted principals are matched by username prefix and group"
  }
  assert {
    condition     = strcontains(kubectl_manifest.client_admission_policy[0].yaml_body, "oldObject == null") && strcontains(kubectl_manifest.client_admission_policy[0].yaml_body, "^preview-") && yamldecode(kubectl_manifest.client_admission_binding[0].yaml_body).spec.validationActions == ["Deny"] && yamldecode(kubectl_manifest.client_admission_binding[0].yaml_body).spec.matchResources.namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "dex"
    error_message = "both the new and the old object must carry a preview id, and the binding denies"
  }
}

run "no_client_admission_by_default" {
  command = plan

  variables {
    issuer_url = "https://dex.example.com/dex"
    connectors = [{ type = "mockCallback", id = "mock", name = "mock" }]
  }

  assert {
    condition     = length(kubectl_manifest.client_admission_policy) == 0 && length(kubernetes_secret_v1.connector_env) == 0
    error_message = "no policy and no connector Secret unless asked for"
  }
}
