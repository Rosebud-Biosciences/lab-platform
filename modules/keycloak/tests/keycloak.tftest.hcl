mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}

variables {
  hostname = "https://id.example.com"
  database = { host = "pg.example.com", name = "keycloak", username = "keycloak", password = "shh" }
}

run "defaults" {
  command = plan

  assert {
    condition     = helm_release.keycloak.chart == "keycloakx" && helm_release.keycloak.version == "7.3.2"
    error_message = "the codecentric keycloakx chart, pinned"
  }
  assert {
    condition     = strcontains(helm_release.keycloak.values[0], "\"value\": \"https://id.example.com\"") && strcontains(helm_release.keycloak.values[0], "KC_HOSTNAME_BACKCHANNEL_DYNAMIC") && strcontains(helm_release.keycloak.values[0], "admin-fine-grained-authz:v2")
    error_message = "hostname v2 with a dynamic back-channel, and fine-grained admin permissions v2"
  }
  assert {
    condition     = strcontains(helm_release.keycloak.values[0], "\"existingSecret\": \"keycloak-db\"") && !strcontains(helm_release.keycloak.values[0], "shh")
    error_message = "the database password reaches the chart through a Secret, never the values"
  }
  assert {
    condition     = strcontains(helm_release.keycloak.values[0], "KC_BOOTSTRAP_ADMIN_CLIENT_SECRET") && !strcontains(helm_release.keycloak.values[0], "KC_BOOTSTRAP_ADMIN_PASSWORD") && kubernetes_secret_v1.bootstrap_admin.data["client-id"] == "tofu-admin"
    error_message = "the bootstrap admin is a service-account client with a generated secret, not a user with a password"
  }
  assert {
    condition     = output.internal_url == "http://keycloak-http.keycloak.svc.cluster.local" && output.base_url == "https://id.example.com"
    error_message = "outputs name the public and in-cluster URLs"
  }
  assert {
    condition     = strcontains(helm_release.keycloak.values[0], "\"relativePath\": \"/\"") && strcontains(helm_release.keycloak.values[0], "\"type\": \"ClusterIP\"")
    error_message = "served at the root, on a ClusterIP Service by default"
  }
}

run "node_port_for_kind" {
  command = plan

  variables {
    hostname      = "http://keycloak-http.keycloak.svc.cluster.local"
    service_type  = "NodePort"
    node_port     = 30080
    proxy_headers = ""
  }

  assert {
    condition     = strcontains(helm_release.keycloak.values[0], "\"httpNodePort\": 30080") && !strcontains(helm_release.keycloak.values[0], "KC_PROXY_HEADERS")
    error_message = "a fixed NodePort, and no proxy headers trusted when reached directly"
  }
}

run "hostname_must_be_a_base_url" {
  command = plan

  variables {
    hostname = "https://id.example.com/auth"
  }

  expect_failures = [var.hostname]
}

run "public_ingress_publishes_the_realms_not_the_admin_console" {
  command = plan

  variables {
    ingress        = { enabled = true, class_name = "nginx", host = "id.example.com" }
    admin_hostname = "https://keycloak-admin.tail1234.ts.net"
    admin_ingress  = { enabled = true, class_name = "tailscale", host = "keycloak-admin" }
  }

  assert {
    condition     = strcontains(helm_release.keycloak.values[0], "\"path\": \"/realms/lab\"") && strcontains(helm_release.keycloak.values[0], "\"path\": \"/resources\"") && !strcontains(helm_release.keycloak.values[0], "\"path\": \"/\"") && !strcontains(helm_release.keycloak.values[0], "\"path\": \"/realms\"")
    error_message = "the public Ingress serves the platform realm and /resources only: not master, not the admin console"
  }
  assert {
    condition     = strcontains(helm_release.keycloak.values[0], "KC_HOSTNAME_ADMIN") && kubernetes_ingress_v1.admin[0].spec[0].ingress_class_name == "tailscale"
    error_message = "the admin console answers on its own (private) hostname"
  }
}

run "admin_ingress_needs_admin_hostname" {
  command = plan

  variables {
    admin_ingress = { enabled = true, class_name = "tailscale", host = "keycloak-admin" }
  }

  expect_failures = [kubernetes_ingress_v1.admin]
}
