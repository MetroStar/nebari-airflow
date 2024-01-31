variable "name" {
  description = "Chart name"
  type        = string
}

variable "domain" {
  description = "Domain"
  type        = string
}

variable "realm_id" {
  description = "Keycloak realm_id"
  type        = string
}

variable "client_id" {
  description = "OpenID Client ID"
  type        = string
}

variable "base_url" {
  description = "Default URL to use when the auth server needs to redirect or link back to the client"
  type        = string
}

variable "external_url" {
  description = "External url for keycloak auth endpoint"
  type        = string
}

variable "valid_redirect_uris" {
  description = "A list of valid URIs a browser is permitted to redirect to after a successful login or logout"
  type        = list(string)
}

variable "create_namespace" {
  type = bool
}

variable "namespace" {
  type = string
}

variable "ingress" {
  type = object({
    enabled = optional(bool, true)
    path    = string
  })
  default = {
    enabled = false
    path    = "/airflow"
  }
}

variable "affinity" {
  type = object({
    enabled  = optional(bool, true)
    selector = optional(any, "general")
  })

  default = {
    enabled  = false
    selector = "general"
  }

  validation {
    condition     = can(tostring(var.affinity.selector)) || (can(var.affinity.selector.default) && length(try(var.affinity.selector.default, "")) > 0)
    error_message = "\"affinity.selector\" argument must be a string or object { default }"
  }
}

variable "overrides" {
  type    = map(any)
  default = {}
}

variable "auth_enabled" {
  type = bool
}

variable "gitSync" {
  type = object({
    enabled = optional(bool, false)
    repo    = optional(string, "")
    path    = optional(string, "")
    branch  = optional(string, "main")
    credentials = optional(object({
      username = string
      password = string
    }), {
      username = ""
      password = ""
    })
  })
  default = {
    enabled = false
    repo    = ""
    path    = ""
    branch  = "main"
    credentials = {
      username = ""
      password = ""
    }
  }
}

variable "extraEnv" {
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "pythonVersion" {
  type    = string
  default = "3.10"
}

variable "fernet_key" {
  type = string
}
