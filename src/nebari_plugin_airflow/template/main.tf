locals {
  name                = var.name
  domain              = var.domain
  realm_id            = var.realm_id
  client_id           = var.client_id
  base_url            = var.base_url
  valid_redirect_uris = var.valid_redirect_uris
  external_url        = var.external_url

  create_namespace = var.create_namespace
  namespace        = var.namespace
  overrides        = var.overrides
  ingress          = var.ingress
  affinity = var.affinity != null && lookup(var.affinity, "enabled", false) ? {
    enabled = true
    selector = try(
      { for k in ["default"] : k => length(var.affinity.selector[k]) > 0 ? var.affinity.selector[k] : var.affinity.selector.default },
      {
        default = var.affinity.selector
      },
    )
    } : {
    enabled  = false
    selector = null
  }
  auth_enabled  = var.auth_enabled
  fernet_key    = var.fernet_key
  gitSync       = var.gitSync
  extraEnv      = var.extraEnv
  pythonVersion = var.pythonVersion

  chart_namespace = local.create_namespace ? kubernetes_namespace.this[0].metadata[0].name : local.namespace

  roles = local.auth_enabled ? [
    "airflow_admin",
    "airflow_op",
    "airflow_public",
    "airflow_user",
    "airflow_viewer",
  ] : []

  default_values = yamlencode({
    domain           = local.domain
    configSecretName = "${local.name}-webserver-config"

    ingress = {
      ingress = local.ingress.enabled
      host    = local.domain
      path    = local.ingress.path
    }
    auth = {
      enabled = local.auth_enabled
    }
    airflow = {
      airflow = {
        image = {
          repository = "ghcr.io/metrostar/nebari-airflow/airflow"
          tag        = "${yamldecode(file("./chart/Chart.yaml")).appVersion}-python${local.pythonVersion}"
        }
        extraEnv = concat([for k, _ in kubernetes_secret.env.data :
          {
            name = k
            valueFrom = {
              secretKeyRef = {
                name     = kubernetes_secret.env.metadata[0].name
                key      = k
                optional = false
              }
            }
          }
        ], local.extraEnv)
        defaultAffinity = local.affinity.enabled ? {
          nodeAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = {
              nodeSelectorTerms = [
                {
                  matchExpressions = [
                    {
                      key      = "eks.amazonaws.com/nodegroup"
                      operator = "In"
                      values   = [local.affinity.selector.default]
                    }
                  ]
                }
              ]
            }
          }
        } : {}
      }
      web = local.auth_enabled ? {
        podAnnotations = {
          "checksum/plugin-secrets-sha256" = base64sha256(join("", [
            filebase64("./chart/files/webserver_config.py"),
            jsonencode(kubernetes_secret.env.data),
            jsonencode(kubernetes_secret.db.data),
            local.gitSync.enabled ? jsonencode(kubernetes_secret.gitSync[0].data) : "",
          ]))
        }
        webserverConfig = {
          existingSecret = "${local.name}-webserver-config"
        }
      } : {}
      dags = {
        persistence = {
          enabled = !local.gitSync.enabled
        }
        gitSync = local.gitSync.enabled ? {
          enabled     = true
          repo        = local.gitSync.repo
          repoSubPath = local.gitSync.path
          branch      = local.gitSync.branch
          httpSecret  = kubernetes_secret.gitSync[0].metadata[0].name
          } : {
          enabled     = false
          repo        = ""
          repoSubPath = ""
          branch      = ""
          httpSecret  = ""
        }
      }
      postgresql = {
        existingSecret = kubernetes_secret.db.metadata[0].name
      }
    }
  })
}

resource "kubernetes_namespace" "this" {
  count = local.create_namespace ? 1 : 0

  metadata {
    name = local.namespace
  }
}

resource "helm_release" "this" {
  name      = local.name
  chart     = "./chart"
  namespace = local.chart_namespace

  dependency_update = true

  values = [
    local.default_values,
    yamlencode(local.overrides),
  ]
}

resource "keycloak_openid_client" "this" {
  count = local.auth_enabled ? 1 : 0

  realm_id                     = local.realm_id
  name                         = local.client_id
  client_id                    = local.client_id
  access_type                  = "CONFIDENTIAL"
  base_url                     = local.base_url
  valid_redirect_uris          = local.valid_redirect_uris
  enabled                      = true
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  web_origins                  = ["+"]
}

resource "keycloak_openid_audience_protocol_mapper" "this" {
  count = local.auth_enabled ? 1 : 0

  realm_id  = local.realm_id
  client_id = keycloak_openid_client.this[0].id
  name      = "audience"

  included_client_audience = keycloak_openid_client.this[0].name
}

resource "keycloak_role" "this" {
  for_each = toset(local.roles)

  realm_id  = local.realm_id
  client_id = keycloak_openid_client.this[0].id
  name      = each.key
}

resource "keycloak_group" "this" {
  for_each = toset(local.roles)

  realm_id = local.realm_id
  name     = each.key
}

resource "keycloak_group_roles" "this" {
  for_each = toset(local.roles)

  realm_id = local.realm_id
  group_id = keycloak_group.this[each.key].id

  role_ids = [
    keycloak_role.this[each.key].id,
  ]
}

resource "keycloak_generic_role_mapper" "this" {
  for_each = toset(local.roles)

  realm_id  = local.realm_id
  client_id = keycloak_openid_client.this[0].id
  role_id   = keycloak_role.this[each.key].id
}

resource "kubernetes_secret" "env" {
  metadata {
    name      = "${local.name}-plugin-envs"
    namespace = local.chart_namespace
  }

  data = {
    AIRFLOW__CORE__FERNET_KEY      = local.fernet_key
    AIRFLOW__WEBSERVER__SECRET_KEY = random_id.webserver_secret.hex
    AIRFLOW_SSO_ISSUER_URL         = local.auth_enabled ? "${local.external_url}realms/${local.realm_id}" : "_"
    AIRFLOW_SSO_CLIENT_ID          = local.auth_enabled ? keycloak_openid_client.this[0].client_id : "_"
    AIRFLOW_SSO_CLIENT_SECRET      = local.auth_enabled ? keycloak_openid_client.this[0].client_secret : "_"
  }

  lifecycle {
    ignore_changes = [
      data.AIRFLOW__CORE__FERNET_KEY,
    ]
  }
}

resource "kubernetes_secret" "db" {
  metadata {
    name      = "${local.name}-postgres"
    namespace = local.chart_namespace
  }

  data = {
    "postgresql-password" = random_password.db.result
  }
}

resource "kubernetes_secret" "gitSync" {
  count = local.gitSync.enabled ? 1 : 0

  metadata {
    name      = "${local.name}-git-credentials"
    namespace = local.chart_namespace
  }

  data = local.gitSync.credentials
}

resource "random_id" "webserver_secret" {
  byte_length = 32
}

resource "random_password" "db" {
  length  = 24
  special = false
}
