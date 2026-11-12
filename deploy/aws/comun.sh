# comun.sh · lo que comparten los scripts de deploy/aws/ (se carga con: source deploy/aws/comun.sh)
#
# Nombres e IP de docs/red.md. Cada recurso lleva la etiqueta Name (la que se ve en la consola) y
# Proyecto=biblioteca; los scripts buscan por esas etiquetas antes de crear, así que se pueden volver
# a correr: lo que ya existe se reutiliza.
#
# Credenciales: las de «AWS Details» del Learner Lab en ~/.aws/credentials (cambian en cada sesión).
# Se comprueba la cuenta antes de crear nada.

export AWS_PAGER=""
export MSYS_NO_PATHCONV=1                  # Git Bash: que no convierta /biblioteca/... en una ruta de Windows
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
PROYECTO=biblioteca
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Los scripts trabajan parados en deploy/aws/ y nombran sus archivos con rutas relativas (file://...):
# la aws.exe de Windows no entiende rutas de Git Bash como /c/Users/...
cd "$AQUI"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# Los .exe de Windows devuelven \r al final de cada línea: se quita para que las comparaciones funcionen.
aws_() { aws "$@" | tr -d '\r'; }

# Un archivo guardado con CRLF (VS Code en Windows) llega con \r a la máquina y bash falla allá: se le quita.
sin_crlf() {
  local f
  # grep termina con 1 cuando no encuentra nada, y con pipefail eso cortaría el script: se acepta.
  { grep -rlI $'\r' "$@" 2>/dev/null || true; } | while IFS= read -r f; do
    tr -d '\r' < "$f" > "$f.lf" && mv "$f.lf" "$f" && log "$f tenía CRLF: quedó con LF"
  done
}

cuenta() { aws_ sts get-caller-identity --query Account --output text; }
bucket() { echo "biblioteca-l10-$(cuenta)"; }    # el bucket del grupo: cambia el prefijo si quieres

# IP privada fija de cada máquina (los brokers anuncian su IP: si cambiara, nadie los encontraría).
ip_de() {
  case "$1" in
    nat) echo 10.0.1.10;; gw-aws) echo 10.0.1.20;;
    servicios) echo 10.0.11.10;; gestion) echo 10.0.11.20;;
    mq-1) echo 10.0.21.11;; mq-2) echo 10.0.22.12;; mq-3) echo 10.0.21.13;;
    datos) echo 10.0.21.30;;
    *) echo "máquina desconocida: $1" >&2; return 1;;
  esac
}
BROKERS="10.0.21.11:9092,10.0.22.12:9092,10.0.21.13:9092"

etiquetas() { # tipo-de-recurso nombre
  echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Proyecto,Value=$PROYECTO}]"
}
filtros() { echo "Name=tag:Name,Values=$1 Name=tag:Proyecto,Values=$PROYECTO"; }

id_vpc() { aws_ ec2 describe-vpcs --filters $(filtros biblioteca-vpc) --query 'Vpcs[0].VpcId' --output text; }
id_igw() { aws_ ec2 describe-internet-gateways --filters $(filtros biblioteca-igw) \
  --query 'InternetGateways[0].InternetGatewayId' --output text; }
id_subred() { aws_ ec2 describe-subnets --filters $(filtros "$1") --query 'Subnets[0].SubnetId' --output text; }
id_tabla() { aws_ ec2 describe-route-tables --filters $(filtros "$1") --query 'RouteTables[0].RouteTableId' --output text; }
id_sg() { aws_ ec2 describe-security-groups --filters $(filtros "$1") --query 'SecurityGroups[0].GroupId' --output text; }
id_inst() { # la instancia viva con ese Name (no cuenta las terminadas)
  aws_ ec2 describe-instances --filters $(filtros "$1") \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

comprobar_cuenta() {
  local arn
  arn=$(aws_ sts get-caller-identity --query Arn --output text) || { log "Sin credenciales: copia las de AWS Details"; exit 1; }
  case "$arn" in
    *assumed-role/voclabs/*) log "Cuenta $(cuenta) · $arn";;
    *) log "Estas credenciales no son las del Learner Lab ($arn). Revisa ~/.aws/credentials"; exit 1;;
  esac
}

# Espera a que la máquina aparezca Online en Session Manager (necesita nat arriba, salvo nat misma).
esperar_ssm() {
  local inst; inst=$(id_inst "$1")
  for _ in $(seq 1 90); do
    [ "$(aws_ ssm describe-instance-information --filters "Key=InstanceIds,Values=$inst" \
      --query 'InstanceInformationList[0].PingStatus' --output text)" = Online ] && return 0
    sleep 10
  done
  log "$1 ($inst) no aparece Online en Session Manager: revisa nat y la tabla de rutas privada"; return 1
}

# en_maquina <máquina> <comandos> · corre los comandos como root en la máquina, por Session Manager
# (send-command: sin SSH ni puerto 22), espera a que terminen y muestra la salida. Viajan en base64
# para no pelear con comillas; así no hace falta jq.
en_maquina() {
  local inst cid estado b64
  inst=$(id_inst "$1")
  b64=$(printf '%s\n' "$2" | base64 | tr -d '\n')
  cid=$(aws_ ssm send-command --instance-ids "$inst" --document-name AWS-RunShellScript \
    --comment "biblioteca $1" --timeout-seconds 600 \
    --parameters "{\"commands\":[\"f=\$(mktemp); echo $b64 | base64 -d > \$f && bash \$f 2>&1\"],\"executionTimeout\":[\"1800\"]}" \
    --query Command.CommandId --output text) || return 1
  while :; do
    sleep 5
    estado=$(aws_ ssm get-command-invocation --command-id "$cid" --instance-id "$inst" \
      --query Status --output text 2>/dev/null)
    case "$estado" in Pending|InProgress|Delayed|"") ;; *) break;; esac
  done
  aws_ ssm get-command-invocation --command-id "$cid" --instance-id "$inst" \
    --query StandardOutputContent --output text | sed -e '/^[[:space:]]*$/d' -e "s/^/  $1 | /"
  [ "$estado" = Success ] || { log "$1 terminó en $estado"; return 1; }
}
