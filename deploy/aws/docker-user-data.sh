#!/bin/bash
# User data de las EC2 que corren contenedores (Amazon Linux 2023): servicios,
# gestion, gw-aws, mq-1 a mq-3 y datos. Instala Docker y el plugin de Compose,
# que Amazon Linux 2023 no trae en sus repositorios. Las maquinas privadas lo
# descargan a traves de nat: si nat no esta arriba, esto se queda reintentando.
# En la sesion de Session Manager, docker se usa con sudo (el usuario ssm-user no esta en el grupo docker).
for i in $(seq 1 30); do dnf install -y docker && break; sleep 10; done
systemctl enable --now docker
mkdir -p /usr/local/lib/docker/cli-plugins
for i in $(seq 1 30); do
  curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
    https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 && break
  sleep 10
done
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
