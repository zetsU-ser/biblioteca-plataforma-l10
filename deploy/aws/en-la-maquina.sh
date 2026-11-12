#!/bin/bash
# en-la-maquina.sh · lo que se hace DENTRO de cada EC2, por Session Manager y con sudo. Baja deploy/ desde
# S3 a /opt/biblioteca/deploy/, escribe los secretos desde Parameter Store en /opt/biblioteca/secretos/ y
# levanta la pieza pedida. La máquina se reconoce por su IP privada fija (docs/red.md).
#
# Uso, en la máquina (Connect → Session Manager en la consola de EC2, o aws ssm start-session):
#   B=biblioteca-l10-<cuenta>
#   sudo aws s3 sync s3://$B/deploy/ /opt/biblioteca/deploy/
#   sudo bash /opt/biblioteca/deploy/aws/en-la-maquina.sh <pieza> $B
#
# Piezas, en el orden en que se levantan:
#   kafka       mq-1, mq-2 y mq-3: controller y broker (mq/kafka/compose.yml con mq-N.env)
#   topics      mq-1, con las tres mq arriba: mq/kafka/topics.sh contra el broker de mq-1
#   rabbit      mq-1 y mq-2: secretos desde /biblioteca/mq-N/env y mq/rabbit/compose.yml
#   politicas   mq-1, con el clúster de RabbitMQ formado: las políticas de docs/politicas.md
#   datos       datos: secretos desde /biblioteca/datos/env y Postgres 18 (datos/compose.yml)
#   gestion     gestion: Kafka UI (gestion/compose.yml)
#   simulador   gestion: descarga biblioteca-simulador de GitHub y publica la noche contra los 3 brokers.
#               No publica si biblioteca.lecturas ya tiene mensajes (sería el doble); FORZAR=1 lo obliga.
#   estado      cualquiera: los contenedores de la máquina
# Se puede volver a correr: docker compose up no recrea lo que no cambió y topics.sh usa --if-not-exists.
set -eu
export AWS_DEFAULT_REGION=us-east-1
PIEZA="${1:?Uso: sudo bash en-la-maquina.sh <pieza> <bucket>}"
BUCKET="${2:-biblioteca-l10-$(aws sts get-caller-identity --query Account --output text)}"
DEPLOY=/opt/biblioteca/deploy/aws
SECRETOS=/opt/biblioteca/secretos
BROKERS=10.0.21.11:9092,10.0.22.12:9092,10.0.21.13:9092
SIMULADOR=https://github.com/Umbingelelo/biblioteca-simulador

TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
case "$IP" in
  10.0.21.11) M=mq-1;; 10.0.22.12) M=mq-2;; 10.0.21.13) M=mq-3;;
  10.0.21.30) M=datos;; 10.0.11.20) M=gestion;; *) echo "IP $IP: no es una máquina de la E2"; exit 1;;
esac
solo() { case " $* " in *" $M "*) ;; *) echo "La pieza $PIEZA va en: $*. Esta máquina es $M ($IP)."; exit 1;; esac; }
echo "== $M ($IP) · $PIEZA · $(date '+%H:%M:%S')"

# Docker y Compose los instala el user data al arrancar (docker-user-data.sh): se espera a que estén.
for _ in $(seq 1 60); do docker compose version > /dev/null 2>&1 && break; sleep 5; done
docker compose version > /dev/null 2>&1 || { echo "Docker Compose no está instalado: revisa nat y el user data"; exit 1; }

aws s3 sync "s3://$BUCKET/deploy/" /opt/biblioteca/deploy/ --delete --only-show-errors
mkdir -p "$SECRETOS" && chmod 700 "$SECRETOS"

case "$PIEZA" in
  kafka)
    solo mq-1 mq-2 mq-3
    cd "$DEPLOY/mq/kafka"
    docker compose --env-file "$M.env" up -d --wait --quiet-pull
    docker compose --env-file "$M.env" ps --format '{{.Name}}  {{.Status}}'
    ;;
  topics)
    solo mq-1
    cd "$DEPLOY/mq/kafka"
    # topics.sh usa docker compose exec: se le pasa el .env de la máquina para que el compose se lea sin avisos.
    COMPOSE_ENV_FILES=mq-1.env SERVICIO=broker BOOTSTRAP=10.0.21.11:9092 sh topics.sh
    ;;
  rabbit)
    solo mq-1 mq-2
    cd "$DEPLOY/mq/rabbit"
    bash secretos.sh "$M"
    docker compose --env-file "$M.env" up -d --wait --quiet-pull
    docker compose --env-file "$M.env" ps --format '{{.Name}}  {{.Status}}'
    ;;
  politicas)
    solo mq-1
    cd "$DEPLOY/mq/rabbit"
    docker compose --env-file mq-1.env exec -T rabbit rabbitmqctl import_definitions /etc/rabbitmq/politicas.json
    docker compose --env-file mq-1.env exec -T rabbit rabbitmqctl cluster_status | sed -n '/^Disk Nodes/,/^CPU Cores/p'
    ;;
  datos)
    solo datos
    aws ssm get-parameter --with-decryption --name /biblioteca/datos/env \
      --query Parameter.Value --output text > "$SECRETOS/datos.env"
    chmod 600 "$SECRETOS/datos.env"
    cd "$DEPLOY/datos"
    docker compose --env-file "$SECRETOS/datos.env" up -d --wait --quiet-pull
    docker compose --env-file "$SECRETOS/datos.env" ps --format '{{.Name}}  {{.Image}}  {{.Status}}'
    ;;
  gestion)
    solo gestion
    cd "$DEPLOY/gestion"
    docker compose up -d --wait --quiet-pull
    docker compose ps --format '{{.Name}}  {{.Status}}'
    ;;
  simulador)
    solo gestion
    # Cuántos mensajes tiene ya biblioteca.lecturas, según Kafka UI (la máquina no tiene jq; sí python3).
    YA=$(curl -s http://localhost:8080/api/clusters/biblioteca-aws/topics/biblioteca.lecturas \
      | python3 -c 'import json,sys; t=json.load(sys.stdin); print(sum(p["offsetMax"]-p["offsetMin"] for p in t["partitions"]))')
    if [ "$YA" != 0 ] && [ "${FORZAR:-0}" != 1 ]; then
      echo "biblioteca.lecturas ya tiene $YA mensajes: no se publica otra vez (FORZAR=1 para publicar igual)."
      exit 0
    fi
    rm -rf /opt/biblioteca/simulador && mkdir -p /opt/biblioteca/simulador && cd /opt/biblioteca/simulador
    curl -fsSL "$SIMULADOR/archive/refs/heads/main.tar.gz" | tar xz --strip-components 1
    docker pull -q node:24-slim
    docker run --rm -v "$PWD":/app -w /app node:24-slim sh -c \
      "npm ci --no-audit --no-fund && node reproducir.mjs --velocidad ${VELOCIDAD:-60} --brokers $BROKERS"
    ;;
  estado)
    docker ps --format '{{.Names}}  {{.Image}}  {{.Status}}'
    ;;
  *) echo "Pieza desconocida: $PIEZA"; exit 1;;
esac
