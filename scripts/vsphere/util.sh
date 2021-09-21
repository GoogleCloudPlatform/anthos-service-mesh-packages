#!/bin/bash

if [[ ! -z "${LOG_LEVEL}" ]]; then
  set -ex
else
  set -CeE
fi

function fill_unspecified_context() {

  WORK_DIR="$(pwd)"
  echo "Working Dir is set as ${WORK_DIR}"

  if [[ -z "${KUBECONFIG}" ]]; then
    KUBECONFIG="$HOME/.kube/config"
  fi
  alias kubectl="kubectl --kubeconfig ${KUBECONFIG}"

  echo "Using KUBECONFIG ${KUBECONFIG}"

  if [[ -z "${MESH_ID}" ]]; then
    MESH_ID=$(kubectl -n istio-system get IstioOperator installed-state-${REVISION} --output=json  | jq  '.spec.values.global.meshID')
    echo "Mesh ID         is not specified. Set Mesh ID as context cluster meshID: ${MESH_ID}."
  fi

  # use the absolute path for the key file
  if [[ -f "${KEY_FILE}" ]]; then
    KEY_FILE="$(apath -f "${KEY_FILE}")"
    #    readonly KEY_FILE
  elif [[ -n "${KEY_FILE}" ]]; then
    fatal "Couldn't find key file ${KEY_FILE}. "
  fi

  INSTALL_STATE=$(kubectl -n istio-system get IstioOperator -o jsonpath={.items[0]..metadata.name})
  CLUSTER_NAME=$(kubectl -n istio-system get IstioOperator ${INSTALL_STATE} --output=json | jq -r '.spec.values.global.multiCluster.clusterName')
  if [[ -z "${CLUSTER}" ]]; then
    CLUSTER=${CLUSTER_NAME}
    echo "Using CLUSTER ${CLUSTER}"
  elif [[ ${CLUSTER_NAME} != ${CLUSTER} ]]; then
    fatal "Current kubeconfig points to cluster: ${CLUSTER_NAME}, cannot connect to input cluster ${CLUSTER}"
  fi

  CLUSTER_NETWORK=$(kubectl -n istio-system get IstioOperator ${INSTALL_STATE} --output=json | jq -r '.spec.values.global.network')
  if [[ -z "${VM_NETWORK}" ]]; then
    VM_NETWORK="vmnet"
    echo "VM Network      is not specified. Set VM Network as vmnet "
  fi

  if [[ ${CLUSTER_NETWORK} == ${VM_NETWORK} ]]; then
    VM_NETWORK=("${CLUSTER_NETWORK}""vmnet")
    echo "VM Network should not be the same as Cluster Network. Set VM Network as ${VM_NETWORK} "
  else
    echo "Cluster Network: ${CLUSTER_NETWORK}, VM Network: ${VM_NETWORK}"
  fi

  if [[ -z "${REVISION}" ]]; then
    REVISION=""
    echo "REVISION        is not specified. Set REVISION as \"\" ."
  fi

  if [[ -z "${IMAGE}" ]]; then
    IMAGE="rpm"
    echo "IMAGE           is not specified. Set IMAGE as \"rpm\" ."
  fi

  if [[ -z "${VM_NAMESPACE}" ]]; then
    VM_NAMESPACE="default"
    echo "VM NAMESPACE    is not specified. Set VM NAMESPACE as namespace default."
  fi

  # name of the Kubernetes service account you want to use for your VM. Set as "default" by default
  if [[ -z "${SERVICE_ACCOUNT}" ]]; then
    echo "Service Account is not specified. Set Service Account as default"
    SERVICE_ACCOUNT="default"
  fi

  if [[ -z "${OUTPUT_DIR}" ]]; then
    OUTPUT_DIR="${WORK_DIR}"
    echo "Output  Dir     is not specified. Set Output Directory for each VM as ${OUTPUT_DIR}/vm-vm_name"
  else
    echo "Set Output Directory for each VM as ${OUTPUT_DIR}/vm-vm_name"
  fi

  if [[ -z "${VM_DIR}" ]]; then
    VM_DIR="/tmp"
    echo "VM config Dir   is not specified. Set VM config Dir as /tmp in VM"
  fi

  if [[ -z "${VM_NAMESPACE}" ]]; then
    VM_NAMESPACE="default"
    echo "VM NAMESPACE    is not specified. Set VM NAMESPACE as default"
  fi
  NS=$(kubectl get namespace ${VM_NAMESPACE} --ignore-not-found)
  if [[ "${NS}" ]]; then
    echo "Skipping creation of namespace       ${VM_NAMESPACE} - already exists"
  else
    kubectl create namespace ${VM_NAMESPACE}
  fi

  SA=$(kubectl get serviceaccount "${SERVICE_ACCOUNT}" -n "${VM_NAMESPACE}" -o name --ignore-not-found)
  if [[ "${SA}" ]]; then
    echo "Skipping creation of service-account ${SERVICE_ACCOUNT} - already exists"
  else
    kubectl create serviceaccount "${SERVICE_ACCOUNT}" -n "${VM_NAMESPACE}"
  fi

  if [[ ! -z "${LABELS}" ]]; then
    echo "LABELS is set as ${LABELS}"
  fi
}

function read_args() {
  # shellcheck disable=SC2064
  trap "$(shopt -p nocasematch)" RETURN
  shopt -s nocasematch

  if [[ -e ".attachConfig" ]]; then
    rm ".attachConfig"
  fi
  >".attachConfig"
  chmod +wx ".attachConfig"

  while [[ ${#} != 0 ]]; do
    case "${1}" in
    -addr | --address | --vm_ip | --vm-ip)
      export VM_IP="${2}"
      shift 2
      ;;
    -app | --app | --vm_app | --vm-app)
      export VM_APP="${2}"
      shift 2
      ;;
    -context | --context)
      export SELECT_CONTEXT="${2}"
      echo "export SELECT_CONTEXT=${SELECT_CONTEXT}" >>".attachConfig"
      shift 2
      ;;
    -mesh | --mesh_id | --mesh-id)
      export MESH_ID="${2}"
      echo "export MESH_ID=${MESH_ID}" >>".attachConfig"
      shift 2
      ;;
    -net | --network | --vm_network | --vm-network)
      export VM_NETWORK="${2}"
      echo "export VM_NETWORK=${VM_NETWORK}" >>".attachConfig"
      shift 2
      ;;
    -key | --key_file | --ssh-key-file)
      export KEY_FILE="${2}"
      echo "export KEY_FILE=${KEY_FILE}" >>".attachConfig"
      shift 2
      ;;
    -sa | --service_account | --service-account)
      export SERVICE_ACCOUNT="${2}"
      echo "export SERVICE_ACCOUNT=${SERVICE_ACCOUNT}" >>".attachConfig"
      shift 2
      ;;
    -cluster | --cluster | --cluster_name | --cluster-name)
      export CLUSTER="${2}"
      echo "export CLUSTER=${CLUSTER}" >>".attachConfig"
      shift 2
      ;;
    -project | --project | --project_id | --project-id)
      export PROJECT_ID="${2}"
      echo "export PROJECT_ID=${PROJECT_ID}" >>".attachConfig"
      shift 2
      ;;
    -ns | --namespace)
      export VM_NAMESPACE="${2}"
      echo "export VM_NAMESPACE=${VM_NAMESPACE}" >>".attachConfig"
      shift 2
      ;;
    -kubeconfig | --kubeconfig)
      export KUBECONFIG="${2}"
      echo "export KUBECONFIG=${KUBECONFIG}" >>".attachConfig"
      shift 2
      ;;
    -vmdir | --vm-config-dir)
      export VM_DIR="${2}"
      echo "export VM_DIR=${VM_DIR}" >>".attachConfig"
      shift 2
      ;;
    -out | -output | --output-dir)
      export OUTPUT_DIR="${2}"
      echo "export OUTPUT_DIR=${OUTPUT_DIR}" >>".attachConfig"
      shift 2
      ;;
    -labels | --labels)
      LABELS="${2}"
      printf -v LABELS '%s' ${LABELS}
      export LABELS="\"${LABELS}\""
      echo "export LABELS=${LABELS}" >>".attachConfig"
      shift 2
      ;;
    -rev | --revision)
      export REVISION="${2}"
      echo "export REVISION=${REVISION}" >>".attachConfig"
      shift 2
      ;;
    -image | --image)
      export IMAGE="${2}"
      echo "export IMAGE=${IMAGE}" >>".attachConfig"
      shift 2
      ;;
    -nic | --managed-nic)
      export MANAGED_NIC="${2}"
      echo "export MANAGED_NIC=${MANAGED_NIC}" >>".attachConfig"
      shift 2
      ;;
    -maddr | --managed-addr | --managed-address)
      export MANAGED_ADDR="${2}"
      echo "export MANAGED_ADDR=${MANAGED_ADDR}" >>".attachConfig"
      shift 2
      ;;
    *)
      warn "Unknown option ${1}"
      exit 2
      ;;
    esac
  done
}

function  write_config_context() {
  rm -f ${CONTEXT_FILE}
  >${CONTEXT_FILE}
  chmod +x ${CONTEXT_FILE}

  echo "export WORK_DIR=${WORK_DIR}" >>${CONTEXT_FILE}
  echo "export OUTPUT_DIR=${OUTPUT_DIR}" >>${CONTEXT_FILE}
  echo "export KEY_FILE=${KEY_FILE}" >>${CONTEXT_FILE}
  echo "export KUBECONFIG=${KUBECONFIG}" >>${CONTEXT_FILE}
  echo "export PROJECT_ID=${PROJECT_ID}" >>${CONTEXT_FILE}
  echo "export MESH_ID=${MESH_ID}" >>${CONTEXT_FILE}
  echo "export CLUSTER=${CLUSTER}" >>${CONTEXT_FILE}
  echo "export CLUSTER_NETWORK=${CLUSTER_NETWORK}" >>${CONTEXT_FILE}
  echo "export VM_NETWORK=${VM_NETWORK}" >>${CONTEXT_FILE}
  echo "export VM_NAMESPACE=${VM_NAMESPACE}" >>${CONTEXT_FILE}
  echo "export SERVICE_ACCOUNT=${SERVICE_ACCOUNT}" >>${CONTEXT_FILE}
  echo "export VM_DIR=${VM_DIR}" >>${CONTEXT_FILE}
  echo "export IMAGE=${IMAGE}" >>${CONTEXT_FILE}

  if [[ ! -z "${LABELS}" ]]; then
    if [[ ${LABELS:0:1} != "\"" ]] ; then LABELS="\"${LABELS}\"";  fi
    echo "export LABELS=${LABELS}" >>${CONTEXT_FILE}
  fi

  if [[ ! -z "${REVISION}" ]]; then
    echo "export REVISION=${REVISION}" >>${CONTEXT_FILE}
  fi
}

init() {
  # BSD-style readlink apparently doesn't have the same -f toggle on readlink
  case "$(uname)" in
  Linux) APATH="readlink" ;;
  Darwin) APATH="stat" ;;
  *) ;;
  esac
}

function warn() {
  info "[WARNING]: ${1}" >&2
}

function apath() {
  "${APATH}" "${@}"
}

function fatal() {
  error "${1}"
  exit 2
}

function info() {
  echo "${SCRIPT_NAME}: ${1}" >&2
}

function error() {
  info "[ERROR]: ${1}" >&2
}
