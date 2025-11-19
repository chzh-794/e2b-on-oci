job "api" {
  datacenters = ["us-ashburn-1"]
  type        = "service"
  priority    = 90

  constraint {
    attribute = "${node.class}"
    value     = "api"
  }

  group "api-service" {
    network {
      port "api" {
        static = 50001
      }
    }

    service {
      name = "api"
      port = "api"

      check {
        type     = "http"
        name     = "health"
        path     = "/health"
        interval = "10s"
        timeout  = "3s"
        port     = "api"
      }
    }

    task "api" {
      driver = "raw_exec"

      resources {
        memory = 2048
        cpu    = 1000
      }

      env {
        NODE_ID = "$${node.unique.id}"
      }

      config {
        command = "/bin/bash"
        args    = ["-lc", "cd /opt/e2b && set -a && source api.env && set +a && ./bin/e2b-api --port 50001"]
      }
    }
  }
}

