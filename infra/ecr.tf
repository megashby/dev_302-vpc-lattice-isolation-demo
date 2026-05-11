resource "aws_ecr_repository" "proxy" {
  name = "${local.name}-db-proxy"
}

resource "null_resource" "build_and_push" {

  triggers = {
    server_js  = filemd5("../src/ecs/db-proxy/server.js")
    dockerfile = filemd5("../src/ecs/db-proxy/Dockerfile")
  }

  provisioner "local-exec" {
    command = <<EOT
      aws ecr get-login-password --region us-east-1 \
      | docker login --username AWS --password-stdin ${aws_ecr_repository.proxy.repository_url}

      docker build --platform linux/amd64 -t db-proxy ../src/ecs/db-proxy
      docker tag db-proxy:latest ${aws_ecr_repository.proxy.repository_url}:latest
      docker push ${aws_ecr_repository.proxy.repository_url}:latest
    EOT
  }
}