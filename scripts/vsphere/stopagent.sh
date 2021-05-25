#!/bin/bash

if [[ ! -z "${LOG_LEVEL}" ]]; then
  set -ex
else
  set -CeE
fi

DIR="${1}"

sudo systemctl stop istio

if pidof envoy; then
  kill $(eval pidof envoy)
fi

rm -rf /etc/certs/*
rm -rf /var/log/istio
rm -rf /var/run/secrets/tokens

# remove obsolete istiod host on VM
grep -v "istiod" "/etc/hosts" > "o"; mv "o" "/etc/hosts"

cd ${DIR}
rm -f cluster.env hosts istio-token mesh.yaml root-cert.pem runagent.sh
rm -f istio-sidecar.rpm

exit
