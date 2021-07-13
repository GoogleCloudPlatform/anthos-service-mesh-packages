#!/bin/bash

if [[ ! -z "${LOG_LEVEL}" ]]; then
  set -ex
else
  set -CeE
fi

echo "Installing ASM agent"

DIR="${1}"
cd ${DIR}

echo ${DIR}
echo $(pwd)

# Copy root cert and bootstrap token
sudo mkdir -p /etc/certs
sudo cp root-cert.pem /etc/certs/root-cert.pem

sudo mkdir -p /var/run/secrets/tokens
sudo cp istio-token /var/run/secrets/tokens/istio-token

# Installing ASM agent.
sudo rpm -ivh --force istio-sidecar.rpm

sudo cp cluster.env /var/lib/istio/envoy/cluster.env

sudo cp mesh.yaml /etc/istio/config/mesh

echo -e "\xE2\x9C\x94 systemctl start istio"

sudo sh -c 'cat hosts >> /etc/hosts'

sudo mkdir -p /etc/istio/proxy
sudo chown -R istio-proxy /var/lib/istio /etc/certs /etc/istio/proxy /etc/istio/config /var/run/secrets /etc/certs/root-cert.pem

sudo systemctl start istio

exit
