#!/bin/bash

set -CeE

if pidof echo; then
  kill $(eval pidof echo)
fi

sudo systemctl stop istio

if pidof envoy; then
  kill $(eval pidof envoy)
fi

rm -rf /etc/certs/*
rm -rf /var/log/istio

rm -f cluster.env echo hosts istio-token mesh.yaml root-cert.pem runagent.sh

exit