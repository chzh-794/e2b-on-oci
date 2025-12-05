job "orchestrator" {
  type        = "system"
  datacenters = ["us-ashburn-1"]
  priority    = 90

  constraint {
    attribute = "${node.class}"
    value     = "client"
  }

  group "client-orchestrator" {
    network {
      port "orchestrator" {
        static = 5008
      }
      port "proxy" {
        static = 5007
      }
    }

    service {
      name = "orchestrator"
      port = "orchestrator"

      check {
        type         = "tcp"
        name         = "health"
        interval     = "20s"
        timeout      = "5s"
        port         = "orchestrator"
      }
    }

    task "orchestrator" {
      driver = "raw_exec"
      # user = "root"  # Removed: AWS doesn't specify user, let it default to Nomad agent user

      resources {
        memory = 2048
        cpu    = 1000
      }

      env {
        NODE_ID = "$${node.unique.id}"
        STORAGE_PROVIDER                 = "Local"
        LOCAL_TEMPLATE_STORAGE_BASE_PATH = "/var/e2b/templates"
        TEMPLATE_BUCKET_NAME             = "local"
        ARTIFACTS_REGISTRY_PROVIDER      = "${ARTIFACTS_REGISTRY_PROVIDER}"
        SANDBOX_DEBUG_VM_LOGS            = "true"
        OCI_REGION                       = "${OCI_REGION}"
        OCIR_NAMESPACE                   = "${OCIR_NAMESPACE}"
        OCIR_TEMPLATE_REPOSITORY_PATH    = "${OCIR_TEMPLATE_REPOSITORY_PATH}"
        OCIR_USERNAME                    = "${OCIR_USERNAME}"
        OCIR_PASSWORD                    = "${OCIR_PASSWORD}"
      }

      config {
        command = "/opt/e2b/bin/orchestrator-wrapper.sh"
        args    = []
      }
    }
  }
}
