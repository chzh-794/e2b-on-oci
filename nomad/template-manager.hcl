job "template-manager" {
  datacenters = ["__REGION__"]
  type        = "service"
  priority    = 70
  meta = {
    storage_mode = "oci"
  }

  reschedule {
    attempts  = 3
    interval  = "45s"
    delay     = "5s"
    max_delay = "2m"
    unlimited = false
  }

  constraint {
    attribute = "${node.class}"
    value     = "client"
  }

  group "template-manager" {
    network {
      port "template" {
        static = 5009
      }
      port "proxy" {
        static = 15007
      }
    }

    service {
      name = "template-manager"
      port = "template"
    }

    task "template-manager" {
      driver = "raw_exec"
      # user = "root"  # Removed: AWS doesn't specify user, let it default to Nomad agent user

      resources {
        memory = 4096
        cpu    = 1000
      }

      env {
        NODE_ID                          = "$${node.unique.id}"
        STORAGE_PROVIDER                 = "OCIBucket"
        TEMPLATE_BUCKET_NAME             = "fc-template"
        ARTIFACTS_REGISTRY_PROVIDER      = "OCI_OCIR"
        OCI_REGION                       = "us-ashburn-1"
        OCI_NAMESPACE                    = "replace-with-namespace"
        OCI_CONTAINER_REPOSITORY_NAME    = "e2b-templates"
        SANDBOX_DEBUG_VM_LOGS            = "true"
      }

      config {
        command = "/bin/bash"
        args    = [
          "-lc",
          "cd /opt/e2b && export NODE_ID=\"${NODE_ID}\" && set -a && source template-manager.env && set +a && ./bin/template-manager --port 5009 --proxy-port 15007"
        ]
      }
    }
  }
}
