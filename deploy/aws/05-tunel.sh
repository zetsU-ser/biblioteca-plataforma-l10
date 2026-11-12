#!/usr/bin/env bash
# 05-tunel.sh · Abre Kafka UI de gestion en http://localhost:18085 con un túnel de Session Manager.
# sg-gestion no abre ningún puerto: el túnel va por el agente de Session Manager, de adentro hacia afuera.
# El 8085 es el del compose local; por eso el túnel usa el 18085 y los dos pueden estar abiertos a la vez.
#
# Requisito: el Session Manager plugin instalado en el equipo (session-manager-plugin en el PATH).
# Uso, desde la raíz de biblioteca-plataforma:
#   bash deploy/aws/05-tunel.sh            # queda abierto hasta Ctrl+C
#   PUERTO=18086 bash deploy/aws/05-tunel.sh
set -euo pipefail
source "$(dirname "$0")/comun.sh"
PUERTO="${PUERTO:-18085}"
GESTION=$(id_inst gestion)
log "Túnel a Kafka UI de gestion ($GESTION): http://localhost:$PUERTO · Ctrl+C para cerrarlo"
aws ssm start-session --target "$GESTION" --document-name AWS-StartPortForwardingSession \
  --parameters "portNumber=8080,localPortNumber=$PUERTO"
