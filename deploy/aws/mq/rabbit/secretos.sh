#!/bin/bash
# secretos.sh · escribe en /opt/biblioteca/secretos/ lo que RabbitMQ necesita y no se versiona:
# rabbitmq.conf (clúster, usuario y clave) y erlang.cookie (dueño 999, modo 400).
# Lee el parámetro /biblioteca/<mq-N>/env de Parameter Store con el rol de la máquina (LabInstanceProfile).
# Uso, en mq-1 o mq-2 por Session Manager:   sudo bash secretos.sh mq-1
set -eu
MAQUINA="${1:?Uso: sudo bash secretos.sh mq-1|mq-2}"
S=/opt/biblioteca/secretos
mkdir -p "$S" && chmod 700 "$S"
aws ssm get-parameter --region us-east-1 --with-decryption --name "/biblioteca/$MAQUINA/env" \
  --query Parameter.Value --output text > "$S/$MAQUINA.env"
chmod 600 "$S/$MAQUINA.env"
. "$S/$MAQUINA.env"     # RABBITMQ_USER, RABBITMQ_PASSWORD y RABBITMQ_COOKIE
cat > "$S/rabbitmq.conf" <<EOF
cluster_formation.peer_discovery_backend = classic_config
cluster_formation.classic_config.nodes.1 = rabbit@mq-1
cluster_formation.classic_config.nodes.2 = rabbit@mq-2
default_user = $RABBITMQ_USER
default_pass = $RABBITMQ_PASSWORD
EOF
chown 999:999 "$S/rabbitmq.conf" && chmod 600 "$S/rabbitmq.conf"   # lleva la clave: solo rabbitmq lo lee
# La cookie: una línea sin salto final, y solo legible por rabbitmq (si no, el nodo no arranca).
rm -f "$S/erlang.cookie"
printf '%s' "$RABBITMQ_COOKIE" > "$S/erlang.cookie"
chown 999:999 "$S/erlang.cookie" && chmod 400 "$S/erlang.cookie"
echo "secretos de $MAQUINA escritos en $S: $(ls "$S" | tr '\n' ' ')"
