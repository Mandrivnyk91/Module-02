# terraform {
#   required_version = ">= 1.5"

#   required_providers {
#     helm = {
#       source  = "hashicorp/helm"
#       version = "~> 2.17"
#     }
#     kubernetes = {
#       source  = "hashicorp/kubernetes"
#       version = "~> 2.35"
#     }
#   }
# }

# variable "kubeconfig_path" {
#   type    = string
#   default = "~/.kube/config"
# }

# variable "kube_context" {
#   type    = string
#   default = null
# }

# variable "namespace" {
#   type    = string
#   default = "monitoring"
# }

# # Закріпіть версії чартів після першого успішного деплою (helm search repo --versions)
# variable "kps_chart_version" {
#   type    = string
#   default = null
# }

# variable "loki_chart_version" {
#   type    = string
#   default = null
# }

# variable "alloy_chart_version" {
#   type    = string
#   default = null
# }

# provider "kubernetes" {
#   config_path    = var.kubeconfig_path
#   config_context = var.kube_context
# }

# provider "helm" {
#   kubernetes {
#     config_path    = var.kubeconfig_path
#     config_context = var.kube_context
#   }
# }

locals {
  loki_url         = "http://loki.monitoring.svc.cluster.local:3100"
  alertmanager_url = "http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093"
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  namespace  = "monitoring"
  create_namespace = true
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  timeout    = 900

  values = [yamlencode({
    grafana = {
      adminPassword = "change-me"
      sidecar = {
        dashboards = {
          enabled         = true
          label           = "grafana_dashboard"
          labelValue      = "1"
          searchNamespace = "ALL"
        }
      }
      additionalDataSources = [
        {
          name      = "Loki"
          type      = "loki"
          uid       = "loki"
          access    = "proxy"
          url       = local.loki_url
          isDefault = false
        }
      ]
    }
  })]
}

resource "helm_release" "loki" {
  name       = "loki"
  namespace  = "monitoring"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  timeout    = 600

  values = [yamlencode({
    deploymentMode = "SingleBinary"

    loki = {
      auth_enabled = false
      commonConfig = {
        replication_factor = 1
      }
      schemaConfig = {
        configs = [{
          from         = "2024-04-01"
          store        = "tsdb"
          object_store = "filesystem"
          schema       = "v13"
          index = {
            prefix = "loki_index_"
            period = "24h"
          }
        }]
      }
      storage = { type = "filesystem" }
      limits_config = {
        retention_period = "168h"
      }
      rulerConfig = {
        alertmanager_url = local.alertmanager_url
        enable_api       = true
        rule_path        = "/tmp/loki/scratch"
        storage = {
          type  = "local"
          local = { directory = "/rules" }
        }
      }
    }

    singleBinary = {
      replicas = 1
      persistence = {
        enabled = true
        size    = "10Gi"
      }
    }
    backend = { replicas = 0 }
    read    = { replicas = 0 }
    write   = { replicas = 0 }

    gateway      = { enabled = false }
    chunksCache  = { enabled = false }
    resultsCache = { enabled = false }
    lokiCanary   = { enabled = false }
    test         = { enabled = false }

    sidecar = {
      rules = { enabled = true }
    }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "helm_release" "alloy" {
  name       = "alloy"
  namespace  = "monitoring"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"

  values = [yamlencode({
    controller = { type = "daemonset" }

    alloy = {
      configMap = {
        content = <<-EOT
          discovery.kubernetes "pods" {
            role = "pod"
            selectors {
              role  = "pod"
              field = "spec.nodeName=" + coalesce(sys.env("HOSTNAME"), constants.hostname)
            }
          }

          discovery.relabel "pod_logs" {
            targets = discovery.kubernetes.pods.targets

            rule {
              source_labels = ["__meta_kubernetes_namespace"]
              target_label  = "namespace"
            }
            rule {
              source_labels = ["__meta_kubernetes_pod_name"]
              target_label  = "pod"
            }
            rule {
              source_labels = ["__meta_kubernetes_pod_container_name"]
              target_label  = "container"
            }
            rule {
              source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
              target_label  = "app"
            }
            rule {
              source_labels = ["__meta_kubernetes_pod_node_name"]
              target_label  = "node"
            }
          }

          loki.source.kubernetes "pods" {
            targets    = discovery.relabel.pod_logs.output
            forward_to = [loki.write.default.receiver]
          }

          loki.source.kubernetes_events "events" {
            job_name   = "integrations/kubernetes/events"
            log_format = "logfmt"

            forward_to = [loki.write.default.receiver]
          }

          loki.write "default" {
            endpoint {
              url = "${local.loki_url}/loki/api/v1/push"
            }
          }
        EOT
      }
    }
  })]

  depends_on = [helm_release.loki]
}

# resource "kubernetes_config_map_v1" "loki_rules_kyverno" {
#   metadata {
#     name      = "loki-rules-kyverno"
#     namespace = "monitoring"
#     labels = {
#       loki_rule = "1"
#     }
#     annotations = {
#       # auth_enabled=false => tenant "fake"
#       "k8s-sidecar-target-directory" = "/rules/fake"
#     }
#   }

#   data = {
#     "kyverno-rorfs.yaml" = <<-EOT
#       groups:
#         - name: kyverno-audit
#           rules:
#             - alert: KyvernoReadOnlyRootFsAuditFail
#               expr: |
#                 sum(
#                   count_over_time(
#                     {namespace="kyverno"}
#                       |~ "(?i)validate-readOnlyRootFilesystem|Root filesystem must be read-only"
#                     [5m]
#                   )
#                 ) > 0
#               for: 0m
#               labels:
#                 severity: warning
#               annotations:
#                 summary: "Kyverno audit: readOnlyRootFilesystem check failed"
#                 description: "Found errors readOnlyRootFilesystem."
#     EOT
#   }

#   depends_on = [helm_release.loki]
# }

output "grafana_port_forward" {
  value = "kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
}
