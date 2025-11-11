job "client-proxy" {
  datacenters = ["ap-osaka-1"]
  type        = "service"
  priority    = 80

  reschedule {
    attempts  = 3
    interval  = "45s"
    delay     = "5s"
    max_delay = "2m"
    unlimited = false
  }

  constraint {
    attribute = "${node.class}"
    value     = "api"
  }

  group "client-proxy" {
    network {
      port "http" {
        static = 3001
      }
      port "metrics" {
        static = 3002
      }
    }

    service {
      name = "client-proxy"
      port = "http"

      check {
        type     = "http"
        name     = "health"
        path     = "/health"
        interval = "10s"
        timeout  = "3s"
        port     = "http"
      }
    }

    task "client-proxy" {
      driver = "raw_exec"

      resources {
        memory = 512
        cpu    = 500
      }

      env {
        NODE_ID = "$${node.unique.id}"
        NODE_IP = "$${attr.unique.network.ip-address}"
      }

      config {
        command = "/bin/bash"
        args    = [
          "-lc",
          "cd /opt/e2b && set -a && source client-proxy.env && set +a && ./bin/client-proxy --port 3001 --metrics-port 3002"
        ]
      }
    }
  }
}
