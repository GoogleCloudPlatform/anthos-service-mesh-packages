# ASM CA migration helper

This directory contains the following files.

## migrate\_ca

This script helps the Citadel to Mesh CA migration process.
It is able to check the following for each pod in the cluster:

- The root certificate (Citadel / Mesh CA).
- The workload mTLS certificate (issued by Citadel / Mesh CA).
- The trust domains configured (Citadel / Mesh CA).

Currently, the script is only designed to work with GKE on GCP.
Users need to set the kube context to the current cluster in order to run the script.

This script has the following dependencies:

- awk
- grep
- istioctl
- jq
- kubectl
- openssl
