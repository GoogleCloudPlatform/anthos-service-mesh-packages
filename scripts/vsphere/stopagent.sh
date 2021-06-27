#!/bin/bash

set -CeE

DIR="${1}"

sudo systemctl stop istio

if pidof envoy; then
  kill $(eval pidof envoy)
fi

rm -rf /etc/certs/*
rm -rf /var/log/istio

cd ${DIR}
rm -f cluster.env hosts istio-token mesh.yaml root-cert.pem runagent.sh

exit
