help_subcommand() {
  local PRINT_HELP; PRINT_HELP=0
  local PRINT_VERSION; PRINT_VERSION=0
  local VERBOSE; VERBOSE=0

  while [[ $# != 0 ]]; do
    case "${1}" in
      -v | --verbose)
        VERBOSE=1
        shift 1
        ;;
      -h | --help)
        PRINT_HELP=1
        shift 1
        ;;
      --version)
        PRINT_VERSION=1
        shift 1
        ;;
      *)
        fatal_with_usage "Unknown subcommand ${1}"
        ;;
    esac
  done

  if [[ "${PRINT_HELP}" -eq 1 || "${PRINT_VERSION}" -eq 1 ]]; then
    if [[ "${PRINT_VERSION}" -eq 1 ]]; then
      version_message
    elif [[ "${VERBOSE}" -eq 1 ]]; then
      usage
    else
      usage_short
    fi
    exit
  fi
}

version_message() {
  local VER; VER="${MAJOR}.${MINOR}.${POINT}-asm.${REV}+config${CONFIG_VER}";
  if [[ "${_CI_CRC_VERSION}" -eq 1 ]]; then
    VER="${VER}-$(crc32 "$0")"
  fi
  echo "${VER}"
}

usage() {
  cat << EOF
${SCRIPT_NAME} $(version_message)
usage: ${SCRIPT_NAME} [SUBCOMMAND] [OPTION]...

Set up, validate, and install ASM in a Google Cloud environment.
Single argument options can also be passed via environment variables by using
the ALL_CAPS name. Options specified via flags take precedence over environment
variables.

SUBCOMMANDS:
  install                             Install will attempt a new ASM installation
  validate                            Validate will attempt a new ASM validation
  print-config                        Print Config will attempt to print the configurations used
  create-mesh                         Add multiple clusters to the mesh
  build-offline-package               Download required packages for offline installation

OPTIONS:
  -l|--cluster_location  <LOCATION>   The GCP location of the target cluster.
  -n|--cluster_name      <NAME>       The name of the target cluster.
  -p|--project_id        <ID>         The GCP project ID.
  --kc|--kubeconfig <KUBECONFIG_FILE> Path to the kubeconfig file to use for CLI requests.
                                      Required if not supplying --cluster_location,
                                      --cluster_name, --project_id in order to locate
                                      and connect to the intended cluster.
  --ctx|--context        <CONTEXT>    The name of the kubeconfig context to use.
  --fleet_id             <FLEET ID>   The Fleet host project ID. Required for non-GCP
                                      clusters. When not provided for GCP clusters, it
                                      defaults to the cluster's project ID.
  --network_id          <NETWORK ID>  The value for topology.istio.io/network label that
                                      will be applied to the istio-system namespace. For GKE,
                                      defaults to the network name for the cluster. For other
                                      environments, "default" will be used.
  -c|--ca                <CA>         The type of certificate authority to be
                                      used. Defaults to "mesh_ca" for install.
                                      Allowed values for <CA> are {citadel|mesh_ca|gcp_cas}.
  -o|--option            <FILE NAME>  The name of a YAML file in the kpt pkg to
                                      apply. For options, see the
                                      anthos-service-mesh-package GitHub
                                      repo under GoogleCloudPlatform. Files
                                      should be in "asm/istio/options" folder,
                                      and shouldn't include the .yaml extension.
                                      (See https://git.io/JTDdi for options.)
                                      To add multiple files, specify them with
                                      multiple options one at a time.
  -s|--service_account   <ACCOUNT>    The name of a service account used to
                                      install ASM. If not specified, the gcloud
                                      user currently configured will be used.
  -k|--key_file          <FILE PATH>  The key file for a service account. This
                                      option can be omitted if not using a
                                      service account.
  -D|--output_dir        <DIR PATH>   The directory where this script will place
                                      downloaded ASM packages and configuration.
                                      If not specified, a temporary directory
                                      will be created. If specified and the
                                      directory already contains the necessary
                                      files, they will be used instead of
                                      downloading them again.
  --co|--custom_overlay  <FILE PATH>  The location of a YAML file to overlay on
                                      the ASM IstioOperator. This option can be
                                      omitted if not installing optional
                                      features. To add multiple files, specify
                                      them with multiple options one at a time.
  --ca_pool              <CA POOL>    Required only if --ca option is gcp_cas.
                                      Name of the ca pool in the GCP CAS service used to
                                      sign certificates in the format
                                      'projects/project_name/locations/ \
                                      ca_region/caPools/ca_pool'. If certificate template
                                      needs to be specified, the format is 'projects/ \
                                      project_name/locations/ca_region/caPools/ \
                                      ca_pool:projects/project_name/locations/ca_region/ \
                                      certificateTemplates/cert_template'.
  -r|--revision_name <REVISION NAME>  Custom revision label. Label needs to follow DNS
                                      label formats (re: RFC 1123). Not supported if
                                      control plane is managed. Prefixing the revision
                                      name with 'asm' is recommended.
  --platform             <PLATFORM>   The platorm or the provider of the kubernetes
                                      cluster. Defaults to "gcp" (for GKE clusters).
                                      For all other platforms use "multicloud".
                                      Allowed values for <PLATFORM> are {gcp|multicloud}.
  --channel              <CHANNEL>    The release channel for the control plane revision.
                                      If the user specifies the channel to be used, only
                                      the Control Plane Revision associated with this
                                      channel will be provisioned. Otherwise, the mapping
                                      between Multicloud/GKE channel and the ASM Channel is
                                      as following:
                                      For Multicloud:
                                        ASM provisions Regular channel.
                                      For GKE:
                                        GKE Channel  |  ASM Channel
                                        -------------|----------------
                                        Rapid        |  Rapid
                                        Regular      |  Regular
                                        Stable       |  Stable
                                        Static       |  Regular

  The following four options must be passed together and are only necessary
  for using a custom certificate for Citadel. Users that aren't sure whether
  they need this probably don't.

  --ca_cert              <FILE PATH>  The intermediate certificate
  --ca_key               <FILE PATH>  The key for the intermediate certificate
  --root_cert            <FILE PATH>  The root certificate
  --cert_chain           <FILE PATH>  The certificate chain

FLAGS:

  The following several flags all relate to allowing the script to create, set,
  or enable required APIs, roles, or services. These can all be performed
  manually before running the script if desired. To allow the script to perform
  every necessary action, pass the -e|--enable_all flag. All of these flags
  are incompatible with --only_validate.

  -e|--enable_all                     Allow the script to perform all of the
                                      individual enable actions below. (Fleet
                                      registration won't happen unless necessary
                                      for a selected option.)
     --enable_cluster_roles           Allow the script to attempt to set
                                      the necessary cluster roles.
     --enable_cluster_labels          Allow the script to attempt to set
                                      necessary cluster labels.
     --enable_gcp_apis                Allow the script to enable GCP APIs on
                                      the user's behalf
     --enable_gcp_iam_roles           Allow the script to set the required GCP
                                      IAM permissions
     --enable_gcp_components          Allow the script to enable required GCP
                                      managed services and components
     --enable_meshconfig_init         Allow the script to initialize the meshconfig
                                      endpoint on your behalf. Implied by
                                      --enable_gcp_components and --managed.
     --enable_registration            Allow the script to register the cluster
                                      to a fleet
     --enable_namespace_creation      Allow the script to create the istio-system
                                      namespace for the user
     --use_managed_cni                Use managed CNI experience. Experimental install
                                      only. If not passed, asmcli will apply the static
                                      CNI manifests.

     --managed                        Provision a remote, managed control plane
                                      instead of installing one in-cluster.
     --legacy                         Provision a remote, managed control plane with
                                      the legacy asmcli installer that runs client-side.
     --use_vpcsc                      Provision a remote, managed control plane in
                                      VPCSC environment. Not supported for --legacy
                                      installation method.
     --offline                        Perform an offline installation using the pre-downloaded
                                      package in the output directory. If the directory is not
                                      specified or does not contain the required files, the 
                                      script will exit with error.

     --print_config                   Instead of installing ASM, print all of
                                      the compiled YAML to stdout. All other
                                      output will be written to stderr, even if
                                      it would normally go to stdout. Skip all
                                      validations and setup.
     --disable_canonical_service      Do not install the CanonicalService
                                      controller. This is required for ASM UI to
                                      support various features.
  --managed_certificates              Enable the managed certificates, which automatically manages
                                      the workload certificates. When this flag is enabled,
                                      you should not specify the --ca option.
  -v|--verbose                        Print commands before and after execution.
     --dry_run                        Print commands, but don't execute them.
     --only_validate                  Run validation, but don't install.
     --only_enable                    Perform the specified steps to set up the
                                      current user/cluster but don't install
                                      anything.
  -h|--help                           Show this message and exit.
  --version                           Print the version of this tool and exit.

EXAMPLE:
The following invocation will install ASM to a cluster named "my_cluster" in
project "my_project" in region "us-central1-c" using the default "mesh_ca" as
the certificate authority:
  $> ${SCRIPT_NAME} \\
      install \\
      -n my_cluster \\
      -p my_project \\
      -l us-central1-c \\

  or

  $> ${SCRIPT_NAME} \\
      install \\
      --kubeconfig kubeconfig_file \\
      --context kube context \\
EOF
}

### CLI/initial setup functions ###
usage_short() {
  cat << EOF
${SCRIPT_NAME} $(version_message)
usage: ${SCRIPT_NAME} [SUBCOMMAND] [OPTION]...

Set up, validate, and install ASM in a Google Cloud environment.
Use -h|--help with -v|--verbose to show detailed descriptions.

SUBCOMMANDS:
  install
  validate
  print-config
  create-mesh
  build-offline-package

OPTIONS:
  -l|--cluster_location  <LOCATION>
  -n|--cluster_name      <NAME>
  -p|--project_id        <ID>
  --kc|--kubeconfig      <KUBECONFIG_FILE>
  --ctx|--context        <CONTEXT>
  --fleet_id             <FLEET ID>
  --network_id           <NETWORK ID>
  -c|--ca                <CA>

  -o|--option            <FILE NAME>
  -s|--service_account   <ACCOUNT>
  -k|--key_file          <FILE PATH>
  -D|--output_dir        <DIR PATH>
  --co|--custom_overlay  <FILE NAME>

  --ca_cert              <FILE PATH>
  --ca_key               <FILE PATH>
  --root_cert            <FILE PATH>
  --cert_chain           <FILE PATH>
  --ca_pool              <CA POOL>
  -r|--revision_name     <REVISION NAME>
  --platform             <PLATFORM>
  --channel              <CHANNEL>

FLAGS:
  -e|--enable_all
     --enable_cluster_roles
     --enable_cluster_labels
     --enable_gcp_apis
     --enable_gcp_iam_roles
     --enable_gcp_components
     --enable_meshconfig_init
     --enable_registration
     --enable_namespace_creation
     --use_managed_cni

     --managed
     --legacy
     --use_vpcsc

     --offline

     --print_config
     --disable_canonical_service
  --managed_certificates
  -v|--verbose
     --dry_run
     --only_validate
     --only_enable
  -h|--help
  --version
EOF
}

create-mesh_usage() {
  cat << EOF
${SCRIPT_NAME} $(version_message)
usage: ${SCRIPT_NAME} create-mesh FLEET_ID (PROJECT_ID/CLUSTER_LOCATION/CLUSTER_NAME | KUBECONFIG_PATH) ... 

Create a multi-cluster service mesh and allow cross-cluster service discovery. This is done by
registering the clusters to the specified fleet and installing the necessary Kubernetes cluster
secrets to allow ASM to communicate securely.

You can pass in an arbitrary number of clusters at once, either by specifying the project ID,
cluster location, and cluster name (for GKE on GCP clusters only) or the location of a
kubeconfig file that has the default context set to the desired cluster.

When adding/removing clusters to an existing multi-cluster fleet, you must specify the entire set
of clusters for every invocation. You cannot add or remove clusters one at a time.

This command will fail if any of the specified clusters are registered to a fleet other than the one
specified by FLEET_ID.

FLAGS:
  All flags must come AFTER the FLEET_ID.
  -D|--output_dir        <DIR PATH>   The directory where this script will place
                                      downloaded ASM packages and configuration.
                                      If not specified, a temporary directory
                                      will be created. If specified and the
                                      directory already contains the necessary
                                      files, they will be used instead of
                                      downloading them again.
  The following several flags are used to display help texts and the version message.
  -v|--verbose                        Print commands before and after execution.
  -h|--help                           Show this message and exit.
  --version                           Print the version of this tool and exit.

EXAMPLE:
The following invocation will create a mesh using the provided 6 clusters
by registering them to a fleet named "my_cluster" and install remote secrets on each pair of clusters:

  $> ${SCRIPT_NAME} \\
      create-mesh \\
      my-fleet \\
      my-project/us-central1-c/my-cluster1 \\
      path/to/kubeconfig2 \\
      my-project/us-central1-c/my-cluster3

EOF
}

create-mesh_usage_short() {
  cat << EOF
${SCRIPT_NAME} $(version_message)
usage: ${SCRIPT_NAME} create-mesh FLEET_ID (PROJECT_ID/CLUSTER_LOCATION/CLUSTER_NAME | KUBECONFIG_PATH) ...

Create a multi-cluster service mesh and allow cross-cluster service discovery.
Use -h|--help with -v|--verbose to show detailed descriptions.

FLAGS:
  -D|--output_dir <DIR PATH>
  -v|--verbose
  -h|--help
  --version
EOF
}


build-offline-package_usage(){
  cat << EOF
${SCRIPT_NAME} $(version_message)
usage: ${SCRIPT_NAME} build-offline-package [FLAGS]...

Download ASM and KPT packages to the specified output directory or a temporary directory.

FLAGS:
  -D|--output_dir        <DIR PATH>   The directory where this script will place
                                      downloaded ASM packages and configuration.
                                      If not specified, a temporary directory
                                      will be created. If specified and the
                                      directory already contains the necessary
                                      files, they will be used instead of
                                      downloading them again.
  The following several flags are used to display help texts and the version message.
  -v|--verbose                        Print commands before and after execution.
  -h|--help                           Show this message and exit.
  --version                           Print the version of this tool and exit.
EOF
}

build-offline-package_usage_short(){
  cat << EOF
${SCRIPT_NAME} $(version_message)
usage: ${SCRIPT_NAME} build-offline-package [FLAGS]...

Download ASM and KPT packages to the specified output directory or a temporary directory.

FLAGS:
  -D|--output_dir <DIR PATH>
  -v|--verbose
  -h|--help
  --version
EOF
}
