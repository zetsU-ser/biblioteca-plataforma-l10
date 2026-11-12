#!/bin/bash
# User data de la EC2 nat (Amazon Linux 2023). Ademas, al lanzarla:
#   aws ec2 modify-instance-attribute --instance-id <id-de-nat> --no-source-dest-check
# y en la tabla de rutas privada: 0.0.0.0/0 hacia la interfaz de red de nat.
# Las dos lineas -F hacen falta: el archivo que trae iptables-services rechaza
# el trafico reenviado. Probado en el Learner Lab: sobrevive a un stop/start.
for i in $(seq 1 30); do dnf install -y iptables-services && break; sleep 10; done
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/90-nat.conf
sysctl -p /etc/sysctl.d/90-nat.conf
IF=$(ip route show default | awk '{print $5; exit}')
iptables -F
iptables -t nat -F
iptables -t nat -A POSTROUTING -o "$IF" -s 10.0.0.0/16 -j MASQUERADE
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables
