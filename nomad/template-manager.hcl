job "template-manager" {
  datacenters = ["ap-osaka-1"]
  type        = "service"
  priority    = 70

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

      resources {
        memory = 4096
        cpu    = 1000
      }

      env {
        NODE_ID                          = "$${node.unique.name}"
        STORAGE_PROVIDER                 = "Local"
        LOCAL_TEMPLATE_STORAGE_BASE_PATH = "/var/e2b/templates"
        TEMPLATE_BUCKET_NAME             = "local"
        ARTIFACTS_REGISTRY_PROVIDER      = "Local"
      }

      config {
        command = "/bin/bash"
        args    = [
          "-lc",
          "cd /opt/e2b && set -a && source template-manager.env && set +a && ./bin/template-manager --port 5009 --proxy-port 15007"
        ]
      }
    }
  }
}
