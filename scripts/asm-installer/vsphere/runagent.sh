#!/bin/bash

set -CeE

echo "Installing ASM agent"

# Copy root cert and bootstrap token
sudo mkdir -p /etc/certs
sudo cp /tmp/root-cert.pem /etc/certs/root-cert.pem

sudo mkdir -p /var/run/secrets/tokens
sudo cp /tmp/istio-token /var/run/secrets/tokens/istio-token

# Installing ASM agent.
sudo rpm -ivh --force istio-sidecar.rpm

sudo cp /tmp/cluster.env /var/lib/istio/envoy/cluster.env

sudo cp /tmp/mesh.yaml /etc/istio/config/mesh

echo -e "\xE2\x9C\x94 systemctl start istio"

sudo sh -c 'cat /tmp/hosts >> /etc/hosts'

sudo mkdir -p /etc/istio/proxy
sudo chown -R istio-proxy /var/lib/istio /etc/certs /etc/istio/proxy /etc/istio/config /var/run/secrets /etc/certs/root-cert.pem

sudo systemctl start istio

# Start echo server
if ! pidof echo > /dev/null; then
  mv server echo
  nohup ./echo &> /dev/null &
fi

exit