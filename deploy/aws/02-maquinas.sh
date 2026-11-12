#!/usr/bin/env bash
# 02-maquinas.sh · Las máquinas de la E2 (docs/red.md): primero nat, con la ruta 0.0.0.0/0 de rt-privada
# hacia su interfaz de red, y después mq-1, mq-2, mq-3, datos y gestion. gw-aws y servicios son de la E3.
#
#   nat         t3.nano, subred publica, IP pública, sin source/dest check, user data nat-user-data.sh
#   las demás   subredes privadas, sin IP pública, user data docker-user-data.sh (Docker y Compose)
#   todas       IP privada fija, LabInstanceProfile (Session Manager, S3 y Parameter Store), sin par de
#               llaves (no hay SSH), etiqueta Name con el nombre de la máquina
#
# Uso, desde la raíz de biblioteca-plataforma, después de 01-red.sh:
#   bash deploy/aws/02-maquinas.sh               # todas las de la E2
#   bash deploy/aws/02-maquinas.sh mq-2          # solo las nombradas (nat se crea igual si falta)
#
# Se puede volver a correr: una máquina que ya existe (encendida o detenida) no se vuelve a crear; si está
# detenida, se enciende.
set -euo pipefail
source "$(dirname "$0")/comun.sh"
comprobar_cuenta
T0=$(date +%s)
sin_crlf nat-user-data.sh docker-user-data.sh

MAQUINAS=("$@"); [ ${#MAQUINAS[@]} -gt 0 ] || MAQUINAS=(mq-1 mq-2 mq-3 datos gestion)
AMI=$(aws_ ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)
log "AMI Amazon Linux 2023: $AMI"

lanzar() { # máquina tipo subred grupo user-data disco ip-pública(si|no)
  local id pub
  id=$(id_inst "$1")
  if [ "$id" != None ]; then
    if [ "$(aws_ ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text)" = stopped ]; then
      aws ec2 start-instances --instance-ids "$id" > /dev/null
      log "$1 estaba detenida: se enciende ($id)"
    else
      log "$1 ya existe: $id"
    fi
    echo "$id"; return
  fi
  [ "$7" = si ] && pub=--associate-public-ip-address || pub=--no-associate-public-ip-address
  id=$(aws_ ec2 run-instances --image-id "$AMI" --instance-type "$2" \
    --subnet-id "$(id_subred "$3")" --private-ip-address "$(ip_de "$1")" $pub \
    --security-group-ids "$(id_sg "$4")" --iam-instance-profile Name=LabInstanceProfile \
    --user-data "file://$5" \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=$6,VolumeType=gp3}" \
    --metadata-options HttpTokens=required \
    --tag-specifications "$(etiquetas instance "$1")" "$(etiquetas volume "$1")" \
    --query 'Instances[0].InstanceId' --output text)
  log "$1 creada: $id ($2, $3, $(ip_de "$1"))"
  echo "$id"
}

# 1 · nat, y la salida a internet de las subredes privadas por su interfaz de red
NAT=$(lanzar nat t3.nano publica sg-nat nat-user-data.sh 8 si)
aws ec2 wait instance-running --instance-ids "$NAT"
aws ec2 modify-instance-attribute --instance-id "$NAT" --no-source-dest-check
ENI=$(aws_ ec2 describe-instances --instance-ids "$NAT" \
  --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text)
RT_PRIV=$(id_tabla rt-privada)
aws ec2 create-route --route-table-id "$RT_PRIV" --destination-cidr-block 0.0.0.0/0 --network-interface-id "$ENI" \
  > /dev/null 2>&1 || aws ec2 replace-route --route-table-id "$RT_PRIV" --destination-cidr-block 0.0.0.0/0 --network-interface-id "$ENI"
log "nat $NAT sin source/dest check; rt-privada ($RT_PRIV) 0.0.0.0/0 -> $ENI"

# 2 · las máquinas con contenedores
for m in "${MAQUINAS[@]}"; do
  case "$m" in
    mq-1|mq-3) lanzar "$m" t3.small datos-a sg-mq docker-user-data.sh 12 no > /dev/null;;
    mq-2)      lanzar "$m" t3.small datos-b sg-mq docker-user-data.sh 12 no > /dev/null;;
    datos)     lanzar "$m" t3.small datos-a sg-datos docker-user-data.sh 12 no > /dev/null;;
    gestion)   lanzar "$m" t3.medium aplicacion sg-gestion docker-user-data.sh 12 no > /dev/null;;
    nat) ;;
    gw-aws|servicios) log "$m es de la E3: no se crea aquí";;
    *) log "máquina desconocida: $m"; exit 1;;
  esac
done

# 3 · que cada una aparezca en Session Manager y tenga Docker (lo baja por nat)
esperar_ssm nat && log "nat Online en Session Manager"
for m in "${MAQUINAS[@]}"; do
  case "$m" in nat|gw-aws|servicios) continue;; esac
  esperar_ssm "$m"
  en_maquina "$m" 'for i in $(seq 1 60); do docker compose version > /dev/null 2>&1 && break; sleep 5; done
echo "$(hostname) $(docker --version | cut -d, -f1) · $(docker compose version) · $(free -m | awk "/Mem/ {print \$2}") MB"'
done

log "Máquinas listas en $(( $(date +%s) - T0 )) s"
aws_ ec2 describe-instances --filters "Name=tag:Proyecto,Values=$PROYECTO" "Name=instance-state-name,Values=pending,running" \
  --output table --query "Reservations[].Instances[].[Tags[?Key=='Name'].Value|[0],InstanceId,InstanceType,PrivateIpAddress,PublicIpAddress]"
