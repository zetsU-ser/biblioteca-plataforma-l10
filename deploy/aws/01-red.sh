#!/usr/bin/env bash
# 01-red.sh · La red de AWS de docs/red.md: VPC 10.0.0.0/16, Internet Gateway, las cuatro subredes,
# las dos tablas de rutas y los seis grupos de reglas. La ruta 0.0.0.0/0 de la tabla privada apunta a
# la interfaz de red de nat, así que la agrega 02-maquinas.sh cuando nat existe.
#
# Uso (Git Bash, macOS o Linux), desde la raíz de biblioteca-plataforma:
#   bash deploy/aws/01-red.sh
#   IP_GW_AZURE=40.116.108.230 bash deploy/aws/01-red.sh    # agrega el 443 de sg-gw solo para gw-azure
#
# Se puede volver a correr: cada recurso se busca por su etiqueta Name y, si ya existe, se reutiliza;
# una regla que ya está se informa y se sigue.
set -euo pipefail
source "$(dirname "$0")/comun.sh"
comprobar_cuenta
T0=$(date +%s)

# 1 · VPC e Internet Gateway
VPC=$(id_vpc)
if [ "$VPC" = None ]; then
  VPC=$(aws_ ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications "$(etiquetas vpc biblioteca-vpc)" \
    --query Vpc.VpcId --output text)
  aws ec2 wait vpc-available --vpc-ids "$VPC"
  log "VPC creada: $VPC"
else
  log "VPC ya existe: $VPC"
fi
aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-hostnames '{"Value":true}'

IGW=$(id_igw)
if [ "$IGW" = None ]; then
  IGW=$(aws_ ec2 create-internet-gateway --tag-specifications "$(etiquetas internet-gateway biblioteca-igw)" \
    --query InternetGateway.InternetGatewayId --output text)
  log "Internet Gateway creado: $IGW"
fi
if [ "$(aws_ ec2 describe-internet-gateways --internet-gateway-ids "$IGW" \
     --query 'InternetGateways[0].Attachments[0].VpcId' --output text)" != "$VPC" ]; then
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
fi
log "Internet Gateway $IGW asociado a $VPC"

# 2 · Subredes: datos-b en otra zona, para que una falla de zona no se lleve las tres mq
subred() { # nombre rango zona
  local id; id=$(id_subred "$1")
  if [ "$id" = None ]; then
    id=$(aws_ ec2 create-subnet --vpc-id "$VPC" --cidr-block "$2" --availability-zone "${AWS_DEFAULT_REGION}$3" \
      --tag-specifications "$(etiquetas subnet "$1")" --query Subnet.SubnetId --output text)
    log "subred $1 ($2, ${AWS_DEFAULT_REGION}$3) creada: $id"
  else
    log "subred $1 ya existe: $id"
  fi
  echo "$id"
}
S_PUB=$(subred publica 10.0.1.0/24 a)
S_APP=$(subred aplicacion 10.0.11.0/24 a)
S_DA=$(subred datos-a 10.0.21.0/24 a)
S_DB=$(subred datos-b 10.0.22.0/24 b)

# 3 · Tablas de rutas: la pública sale por el Internet Gateway; la privada, por nat (02-maquinas.sh)
tabla() { # nombre
  local id; id=$(id_tabla "$1")
  if [ "$id" = None ]; then
    id=$(aws_ ec2 create-route-table --vpc-id "$VPC" --tag-specifications "$(etiquetas route-table "$1")" \
      --query RouteTable.RouteTableId --output text)
    log "tabla de rutas $1 creada: $id"
  else
    log "tabla de rutas $1 ya existe: $id"
  fi
  echo "$id"
}
asociar() { # tabla subred
  local actual
  actual=$(aws_ ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$2" \
    --query 'RouteTables[0].RouteTableId' --output text)
  [ "$actual" = "$1" ] || aws ec2 associate-route-table --route-table-id "$1" --subnet-id "$2" > /dev/null
}
RT_PUB=$(tabla rt-publica)
aws ec2 create-route --route-table-id "$RT_PUB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" \
  > /dev/null 2>&1 || aws ec2 replace-route --route-table-id "$RT_PUB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW"
asociar "$RT_PUB" "$S_PUB"
RT_PRIV=$(tabla rt-privada)
for s in "$S_APP" "$S_DA" "$S_DB"; do asociar "$RT_PRIV" "$s"; done
log "rt-publica ($RT_PUB) con 0.0.0.0/0 al Internet Gateway; rt-privada ($RT_PRIV) en aplicacion, datos-a y datos-b"

# 4 · Grupos de reglas. AWS no acepta nombres de grupo que empiecen con «sg-», así que el nombre del
# grupo es biblioteca-<rol> y la etiqueta Name (la columna Name de la consola) es sg-<rol>.
grupo() { # rol descripción
  local id; id=$(id_sg "sg-$1")
  if [ "$id" = None ]; then
    id=$(aws_ ec2 create-security-group --vpc-id "$VPC" --group-name "biblioteca-$1" --description "$2" \
      --tag-specifications "$(etiquetas security-group "sg-$1")" --query GroupId --output text)
    log "grupo sg-$1 creado: $id"
  else
    log "grupo sg-$1 ya existe: $id"
  fi
  echo "$id"
}
SG_GW=$(grupo gw "gw-aws: 80 para Lets Encrypt y 443 solo desde gw-azure")
SG_NAT=$(grupo nat "nat: salida a internet de las subredes privadas")
SG_SERV=$(grupo servicios "servicios: libros, prestamos y eventos")
SG_GEST=$(grupo gestion "gestion: sin entradas, se entra por Session Manager")
SG_MQ=$(grupo mq "mq-1 a mq-3: Kafka y RabbitMQ")
SG_DATOS=$(grupo datos "datos: Postgres")

# Cada regla nombra otro grupo como origen. Si ya existe, AWS responde InvalidPermission.Duplicate.
regla() { # grupo protocolo desde hasta origen(grupo o rango) para-qué
  local origen puertos salida
  case "$5" in sg-*) origen="UserIdGroupPairs=[{GroupId=$5,Description=\"$6\"}]";;
               *) origen="IpRanges=[{CidrIp=$5,Description=\"$6\"}]";; esac
  puertos="FromPort=$3,ToPort=$4,"; [ "$2" = -1 ] && puertos=""     # -1 = todos los protocolos y puertos
  if salida=$(aws ec2 authorize-security-group-ingress --group-id "$1" \
      --ip-permissions "IpProtocol=$2,$puertos$origen" 2>&1 > /dev/null); then
    if [ "$2" = -1 ]; then log "  regla $1 todo el tráfico desde $5 ($6)"; else log "  regla $1 $2 $3-$4 desde $5 ($6)"; fi
  else
    case "$salida" in *Duplicate*) ;; *) echo "$salida" >&2; return 1;; esac
  fi
}
regla "$SG_GW" tcp 80 80 0.0.0.0/0 "Lets Encrypt y redireccion a HTTPS"
if [ -n "${IP_GW_AZURE:-}" ]; then
  regla "$SG_GW" tcp 443 443 "$IP_GW_AZURE/32" "La API, solo para el BFF en gw-azure"
else
  log "  sin IP_GW_AZURE: el 443 de sg-gw queda para cuando exista gw-azure"
fi
for p in 3001 3002 3010; do
  regla "$SG_SERV" tcp $p $p "$SG_GW" "gateway a libros, prestamos y eventos"
  regla "$SG_SERV" tcp $p $p "$SG_GEST" "el administrador revisa los servicios"
done
for o in "$SG_SERV" "$SG_GEST" "$SG_MQ"; do regla "$SG_MQ" tcp 9092 9092 "$o" "clientes de Kafka y replica"; done
regla "$SG_MQ" tcp 9093 9093 "$SG_MQ" "quorum KRaft"
for o in "$SG_SERV" "$SG_GEST"; do regla "$SG_MQ" tcp 5672 5672 "$o" "AMQP de RabbitMQ"; done
regla "$SG_MQ" tcp 15672 15672 "$SG_GEST" "administracion de RabbitMQ"
regla "$SG_MQ" tcp 4369 4369 "$SG_MQ" "cluster de RabbitMQ (epmd)"
regla "$SG_MQ" tcp 25672 25672 "$SG_MQ" "cluster de RabbitMQ (distribucion Erlang)"
for o in "$SG_SERV" "$SG_GEST"; do regla "$SG_DATOS" tcp 5432 5432 "$o" "Postgres"; done
for o in "$SG_SERV" "$SG_GEST" "$SG_MQ" "$SG_DATOS"; do
  regla "$SG_NAT" -1 -1 -1 "$o" "salida a internet de las privadas"
done

log "Red lista en $(( $(date +%s) - T0 )) s"
echo "VPC=$VPC IGW=$IGW"
echo "publica=$S_PUB aplicacion=$S_APP datos-a=$S_DA datos-b=$S_DB"
echo "rt-publica=$RT_PUB rt-privada=$RT_PRIV"
echo "sg-gw=$SG_GW sg-nat=$SG_NAT sg-servicios=$SG_SERV sg-gestion=$SG_GEST sg-mq=$SG_MQ sg-datos=$SG_DATOS"
