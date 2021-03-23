#!/bin/bash

declare -A rootmap

add_to_rootmap() {
  local output
  local roots

  output=$(istioctl pc secret $1 -n $2 -o json)

  if [ $(echo ${output} | jq '.dynamicActiveSecrets[0].name') = "\"ROOTCA\"" ]; then
    roots=$(echo ${output} | jq '.dynamicActiveSecrets[0].secret.validationContext.trustedCa.inlineBytes')
  else
    roots=$(echo ${output} | jq '.dynamicActiveSecrets[1].secret.validationContext.trustedCa.inlineBytes')
  fi
  if [ -z ${roots} ]; then
    echo "Cannot find roots for $1.$2"
    exit 1
  fi
  echo ${roots} | sed 's/\"//g' | base64 -d > /tmp/$3.pem

  local citadelroot
  local meshcaroot
  citadelroot=$(openssl crl2pkcs7 -nocrl -certfile /tmp/$3.pem | openssl pkcs7 -print_certs -text -noout | grep "Subject: " | grep -v "istio_v1_cloud_workload_root-signer")
  meshcaroot=$(openssl crl2pkcs7 -nocrl -certfile /tmp/$3.pem | openssl pkcs7 -print_certs -text -noout | grep "istio_v1_cloud_workload_root-signer")

  local canames
  [[ -z ${citadelroot} ]] || canames="CITADEL"
  if [ -z ${canames} ]; then
    [[ -z ${meshcaroot} ]] || canames="MESHCA"
  else
    [[ -z ${meshcaroot} ]] || canames="CITADEL MESHCA"
  fi
  rootmap[$3]=${canames}
}

get_issuer_ca() {
  local output
  local certchain

  output=$(istioctl pc secret $1 -n $2 -o json)

  if [ $(echo ${output} | jq '.dynamicActiveSecrets[0].name') = "\"default\"" ]; then
    certchain=$(echo ${output} | jq '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes')
  else
    certchain=$(echo ${output} | jq '.dynamicActiveSecrets[1].secret.tlsCertificate.certificateChain.inlineBytes')
  fi
  if [ -z ${certchain} ]; then
    echo "Cannot find certchain for $1.$2"
    exit 1
  fi
  echo ${certchain} | sed 's/\"//g' | base64 -d > /tmp/certchain.pem

  local meshcaroot
  meshcaroot=$(openssl crl2pkcs7 -nocrl -certfile /tmp/certchain.pem | openssl pkcs7 -print_certs -text -noout | grep "istio_v1_cloud_workload_root-signer")
  if [[ -z ${meshcaroot} ]]; then
    echo $1.$2 is using the mTLS certificate issued by [CITADEL]
  else
    echo $1.$2 is using the mTLS certificate issued by [MESHCA]
  fi
}

check_cert_in_pod() {
  local sn

  # Example format:
  # RESOURCE NAME   TYPE   STATUS   VALID CERT  SERIAL NUMBER        NOT AFTER            NOT BEFORE
  # ROOTCA          CA     ACTIVE   true        16289816804573236346 2117-12-31T19:15:51Z 2018-01-24T19:15:51Z
  # We use the serial number for the comparison.
  if [ "$3" = "ROOTCA" ]; then
    sn=$(istioctl pc secret "$1" -n "$2" | grep "ROOTCA" | awk '{print $5}')
    if [[ -z ${rootmap[${sn}]} ]]; then
      add_to_rootmap $1 $2 ${sn}
    fi
    echo $1.$2 trusts [${rootmap[${sn}]}]
  else
    get_issuer_ca $1 $2
  fi

}

check_cert_in_namespace() {
  local pods
  local containers

  pods=$(kubectl get pod -o jsonpath={.items..metadata.name} -n "$1")
	for pod in ${pods}
	do
    containers=$(kubectl get pod ${pod} -n "$1" -o jsonpath=={.spec.containers.*.name})
    if [[ "${containers}" == *"istio-proxy"* ]]; then
      check_cert_in_pod "${pod}" "$1" "$2"
    fi
	done
}

check_cert() {
  local ns
  ns=$(kubectl get ns -o jsonpath={.items..metadata.name})
  for n in ${ns}
  do
    if [ "$n" != "kube-system" ] && [ "$n" != "kube-public" ] && [ "$n" != "kube-node-lease" ]; then
      echo
      echo "Namespace: $n"
      check_cert_in_namespace "$n" "$1"
    fi
  done
}

case $1 in
  check-root-cert)
    check_cert "ROOTCA"
    ;;

  check-workload-cert)
    check_cert "default"
    ;;
  *)
    echo "Usage: check-root-cert | check-workload-cert

check-root-cert
  Check the root certificates loaded on each Envoy proxy.

check-workload-cert
  Check the CA issuer for the workload certificates on each Envoy proxy.
"

esac
