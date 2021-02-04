WORKLOAD_NAME="vm"
WORKLOAD_SERVICE_ACCOUNT=""
INSTANCE_TEMPLATE_NAME=""

create_service_account() {
  WORKLOAD_SERVICE_ACCOUNT="vm-${LT_NAMESPACE}@${PROJECT_ID}.iam.gserviceaccount.com"
  echo "Creating service account ${WORKLOAD_SERVICE_ACCOUNT}..."
  gcloud iam service-accounts create "${LT_NAMESPACE}" --project "${PROJECT_ID}"
}

create_instance_template() {
  INSTANCE_TEMPLATE_NAME="vm-${LT_NAMESPACE}"
  
  echo "Creating instance template ${INSTANCE_TEMPLATE_NAME}..."
  echo "../../../asm/vm/asm_vm create_gce_instance_template \
      ${INSTANCE_TEMPLATE_NAME} \
      -l ${LT_CLUSTER_LOCATION} \
      -n ${LT_CLUSTER_NAME} \
      -p ${PROJECT_ID} \
      -w ${WORKLOAD_NAME} \
      -ns ${LT_NAMESPACE} \
      ${KEY_FILE} ${SERVICE_ACCOUNT}"
  
  ../../../asm/vm/asm_vm create_gce_instance_template \
    "${INSTANCE_TEMPLATE_NAME}" \
    -l "${LT_CLUSTER_LOCATION}" \
    -n "${LT_CLUSTER_NAME}" \
    -p "${PROJECT_ID}" \
    -w "${WORKLOAD_NAME}" \
    -ns "${LT_NAMESPACE}" \
    "${KEY_FILE}" "${SERVICE_ACCOUNT}"
}

verify_instance_template() {
  # TODO(jasonwzm): include more sophisticated test for proxy config.
  local VAL
  VAL="$(gcloud compute instance-templates list \
    --filter="name=${INSTANCE_TEMPLATE_NAME}" --format="value(name)")"
  if [[ -z "${VAL}" ]]; then
    fail "Cannot find instance template ${INSTANCE_TEMPLATE_NAME} in the project."
    return 1
  fi
}

cleanup_service_account() {
  echo "Deleting service account ${WORKLOAD_SERVICE_ACCOUNT}..."
  gcloud iam service-accounts delete "${WORKLOAD_SERVICE_ACCOUNT}" \
    --quiet --project "${PROJECT_ID}"
}

cleanup_instance_template() {
  echo "Deleting instance template ${INSTANCE_TEMPLATE_NAME}..."
  gcloud compute instance-templates delete "${INSTANCE_TEMPLATE_NAME}" \
    --quiet --project "${PROJECT_ID}"
}