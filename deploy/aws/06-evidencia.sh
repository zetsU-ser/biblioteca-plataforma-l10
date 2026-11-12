#!/usr/bin/env bash
# 06-evidencia.sh · Las salidas que van en texto a docs/despliegue.md (Paso 9 de la E2), más el clúster de
# RabbitMQ y Postgres. Los comandos 1 y 2 se corren en el equipo; del 3 en adelante, en las máquinas por
# Session Manager (send-command): son los mismos que se escriben a mano en mq-1 y en datos.
#
# Uso, desde la raíz de biblioteca-plataforma:
#   bash deploy/aws/06-evidencia.sh | tee deploy/aws/evidencia.txt
set -uo pipefail
source "$(dirname "$0")/comun.sh"
comprobar_cuenta
# Sin el «  mq-1 | » que en_maquina pone delante: así la salida se pega tal cual en docs/despliegue.md.
sin_prefijo() { sed 's/^  [a-z0-9-]* | //'; }

echo "### 1 · Las máquinas y sus IP (privadas sin IP pública, salvo nat)"
aws_ ec2 describe-instances --output table \
  --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" --query \
  "Reservations[].Instances[].[Tags[?Key=='Name'].Value|[0],PrivateIpAddress,PublicIpAddress]"

echo "### 2 · Nadie abre el 22 (lista vacía)"
aws_ ec2 describe-security-groups \
  --filters Name=ip-permission.from-port,Values=22 \
  --query "SecurityGroups[].GroupName"

echo "### 3 a 5 · En mq-1, dentro del contenedor del broker"
en_maquina mq-1 'K="docker exec biblioteca-mq-broker-1 /opt/kafka/bin"
echo "\$ \$K/kafka-metadata-quorum.sh --bootstrap-server 10.0.21.11:9092 describe --status"
$K/kafka-metadata-quorum.sh --bootstrap-server 10.0.21.11:9092 describe --status
echo "\$ \$K/kafka-topics.sh --bootstrap-server 10.0.21.11:9092 --describe --topic biblioteca.prestamos"
$K/kafka-topics.sh --bootstrap-server 10.0.21.11:9092 --describe --topic biblioteca.prestamos
echo "\$ \$K/kafka-get-offsets.sh --bootstrap-server 10.0.21.11:9092 --topic biblioteca.lecturas"
$K/kafka-get-offsets.sh --bootstrap-server 10.0.21.11:9092 --topic biblioteca.lecturas
echo "\$ \$K/kafka-get-offsets.sh --bootstrap-server 10.0.21.11:9092 --topic biblioteca.prestamos"
$K/kafka-get-offsets.sh --bootstrap-server 10.0.21.11:9092 --topic biblioteca.prestamos' | sin_prefijo

echo "### RabbitMQ · el clúster de dos nodos, desde mq-1"
en_maquina mq-1 'docker exec biblioteca-rabbit-rabbit-1 rabbitmqctl cluster_status 2>&1 | sed -n "/^Disk Nodes/,/^Listeners/p" | sed "\$d"' | sin_prefijo

echo "### Postgres · arriba en datos"
en_maquina datos 'docker ps --filter name=biblioteca-datos --format "{{.Names}}  {{.Image}}  {{.Status}}"
docker exec biblioteca-datos-postgres-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB -tAc \"select version()\""' | sin_prefijo
