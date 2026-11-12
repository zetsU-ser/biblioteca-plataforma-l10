#!/usr/bin/env bash
# 04-levantar.sh · Levanta la capa de datos desde el equipo, sin entrar a cada máquina: corre
# en-la-maquina.sh en cada una por Session Manager (send-command). Es lo mismo que hacer a mano, en cada
# máquina (Connect → Session Manager):
#   sudo aws s3 sync s3://<bucket>/deploy/ /opt/biblioteca/deploy/
#   sudo bash /opt/biblioteca/deploy/aws/en-la-maquina.sh <pieza> <bucket>
#
# Orden: Kafka en mq-1..mq-3 (a la vez) → topics desde mq-1 → RabbitMQ en mq-1 y mq-2 (a la vez) →
# políticas en mq-1 → Postgres en datos → Kafka UI en gestion → simulador en gestion.
#
# Uso, desde la raíz de biblioteca-plataforma, después de 03-subir.sh:
#   bash deploy/aws/04-levantar.sh                    # todo
#   bash deploy/aws/04-levantar.sh kafka topics       # solo esas piezas
# Se puede volver a correr: lo que está arriba y no cambió se deja como está, y el simulador no publica
# si los topics ya tienen mensajes (FORZAR=1 bash deploy/aws/04-levantar.sh simulador lo obliga).
set -euo pipefail
source "$(dirname "$0")/comun.sh"
comprobar_cuenta
B=$(bucket)
PIEZAS=("$@"); [ ${#PIEZAS[@]} -gt 0 ] || PIEZAS=(kafka topics rabbit politicas datos gestion simulador)
T0=$(date +%s)

pieza() { # máquina pieza
  en_maquina "$1" "aws s3 sync s3://$B/deploy/ /opt/biblioteca/deploy/ --delete --only-show-errors --region us-east-1
FORZAR=${FORZAR:-0} VELOCIDAD=${VELOCIDAD:-60} bash /opt/biblioteca/deploy/aws/en-la-maquina.sh $2 $B"
}
a_la_vez() { # pieza máquina...  (la salida de cada una se muestra entera, una después de otra)
  local p=$1 m d ok=0; shift
  d=$(mktemp -d)
  for m in "$@"; do ( pieza "$m" "$p" > "$d/$m" 2>&1; echo $? > "$d/$m.rc" ) & done
  wait
  for m in "$@"; do cat "$d/$m"; [ "$(cat "$d/$m.rc")" = 0 ] || ok=1; done
  rm -rf "$d"; return $ok
}

for p in "${PIEZAS[@]}"; do
  T=$(date +%s)
  case "$p" in
    kafka)     a_la_vez kafka mq-1 mq-2 mq-3;;
    topics)    pieza mq-1 topics;;
    rabbit)    a_la_vez rabbit mq-1 mq-2;;
    politicas) pieza mq-1 politicas;;
    datos)     pieza datos datos;;
    gestion)   pieza gestion gestion;;
    simulador) pieza gestion simulador;;
    *) log "pieza desconocida: $p"; exit 1;;
  esac
  log "$p listo en $(( $(date +%s) - T )) s"
done
log "Todo en $(( $(date +%s) - T0 )) s"
