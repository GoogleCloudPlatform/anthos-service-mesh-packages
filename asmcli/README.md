# ASM Installer

There are two scripts `install_asm` and `asm_vm` in this folder that simplify
the installation of the [Anthos Service Mesh] on Google Cloud Platform. This
document describes how to use the scripts.

[Anthos Service Mesh]: https://cloud.google.com/anthos/service-mesh/

- [ASM Installer](#asm-installer)
  - [Downloading the scripts](#downloading-the-scripts)
  - [install\_asm](#install_asm)
    - [Prerequisites for install\_asm](#prerequisites-for-install_asm)
    - [Running install\_asm](#running-install_asm)
    - [Developer notes](#developer-notes)
      - [General](#general)
      - [Using Custom Images](#using-custom-images)
  - [asm\_vm](#asm_vm)
    - [Prerequisites for asm\_vm](#prerequisites-for-asm_vm)
    - [Running asm\_vm](#running-asm_vm)
  - [Release](#release)

## Downloading the scripts

Both scripts are located in the same Google Cloud Storage bucket. Therefore, the
following download instructions also applies to `asm_vm`. Simply replace
`install_asm` with `asm_vm`.

To verify integrity of the script download, you need:

- sha256sum

Download the `install_asm` script by using curl:
`curl -O https://storage.googleapis.com/csm-artifacts/asm/install_asm`

The sha256 of the file is also available:
`curl -O https://storage.googleapis.com/csm-artifacts/asm/install_asm.sha256`

With both files in the same directory, verify the download by using
`sha256sum -c install_asm.sha256`. If you see the message `install_asm: OK`
then verification was successful.

Optionally, you download the script by cloning this repository by using `git`.

After downloading the script, you can add the executable bit to the script or
invoke it directly by using `bash`.

## install\_asm

This script simplifies the installation of [Anthos Service Mesh] on GKE clusters
running on Google Cloud Platform.

### Prerequisites for install\_asm

This script requires access to the following tools:

- awk
- gcloud
- grep
- jq
- kpt
- kubectl
- sed
- tr

Google Cloud Shell pre-installs these tools except `kpt`, which
you can install by using `sudo apt-get install google-cloud-sdk-kpt`.

In addition, you need a GKE Kubernetes cluster with at least 8 vCPUs that use
machine types with at least 4 vCPUs. If you are not the Project Owner for
the GCP Project, you need the following Cloud IAM roles in order to run the
script successfully:

- Kubernetes Engine Admin.
- GKE Hub Admin.
- Service Usage Admin.

### Running install\_asm

Use the script's help flag to see detailed descriptions of its arguments:
`./install_asm --help`. Pass these arguments by using the CLI flag or
environment variables. Set the environment variables by providing the
corresponding flag name in all capital letters. Set toggle flags to 0 to
disable them or 1 to enable them. Descriptions of arguments from the usage
prompt of the script are always more correct than any other source.

There are five required options: CLUSTER\_NAME, CLUSTER\_LOCATION, PROJECT\_ID,
CA, and MODE. Use the first three to specify the cluster where to install
Anthos Service Mesh. Set MODE to `install` for a new installation, or `migrate`
to migrate an Istio 1.7 control plane to Anthos Service Mesh, or `upgrade` in
order to upgrade an ASM installation to ASM 1.7. Upgrades are only supported
from at most one minor version back.

Set `CA` to specify the Certificate Authority. [Mesh CA] is recommended for
new installations. Citadel is supported during migrations to help migrate
workloads safely. Google recommends migrating to Mesh CA when possible. Note
that migrating CAs means changing the root of trust for your encrypted traffic.
It's recommended to attempt this in a non-production environment before your
production one.

The script can enable the required Google Cloud APIs on your behalf, if you
pass the `--enable_apis` flag when you run it. Otherwise, the script will fail
if they are not already enabled.

You can specify an optional YAML file to customize the IstioOperator to apply
to the Kubernetes cluster by using the CUSTOM\_OVERLAY flag. This merges the
specified file with the base Anthos Service Mesh manifest, and allows users to
install optional components at install time.

You can also specify a YAML file from the asm/istio/options folder in this
repo by using the OPTION flag. This is a convenient way to apply configuration
without needing to download the package beforehand. Specify the name without
the .yaml file extension to specify the configuration. (e.g.
`asm/istio/options/optional-configuration-example.yaml` would be passed by
`--option optional-configuration-example`)

If the script is running as a service account and not a user, set the
SERVICE\_ACCOUNT option to the name of the service account, and
set KEY\_FILE to the file that contains the authentication credentials for that
account.

The script automatically validates dependencies and requirements before
installation. Use the `--only_validate` flag to _only_ perform
validation and stop before taking any actions with side effects.

Use the `--dry-run` flag for the script to display commands with side effects
instead of executing them, or use the `--verbose` flag to display _and_ execute
the commands. Combine the --verbose flag with --help to see extended help.

The script prefixes its output with 'install\_asm' to distinguish it from the
output from other tools that it invokes.

The script will by default create a temporary directory in order to download
files and configuration necessary for installing ASM. Specify the --output-dir
flag in order to designate an existing folder to use instead. Upon completion,
the directory will contain the configuration used for installationm, as well as
the ASM package which notably contains the istioctl binary for the installed
version of ASM. For convenience, it also generates the combined configuration
in a single file, in both raw (pre-manifest) and expanded (post-manifest) forms
for later use. The raw form is easier for humans to understand, but in order
to apply the configuration to a Kubernetes cluster you will need to use
`istioctl manifest generate` to expand it, or use the expanded configuration.
These configuration files can be useful if you ever need to roll back to this
state, so saving them is recommended.

[Mesh CA]: https://cloud.google.com/service-mesh/docs/overview#security_features

### Developer notes

#### General

You can use the scripts in the tests/ folder to test different scenarios. In
general, the scripts do the following:

- Create a 4 node GKE cluster
- Install the Google Cloud Platform microservices demo
- Install a variation of Anthos Service Mesh and verify a working gateway.

Important: You must specify a project by using the CLI, and **your project will be billed
for the used resources**. These tests attempt to clean up resources they create, but
but manually verify that all resources are deleted to avoid unexpected costs.

Warning: The cloudbuild.yaml file is for testing purposes only. Do not use this
in any project containing production resources. The Cloud Build configuration
will attempt to delete all GKE clusters older than three hours old.

#### Using Custom Images

If you would like to use the script with custom packages or images (e.g. for
testing pre-release versions), you can do so using environment variables.

`_CI_ASM_PKG_LOCATION` is the name of the Google Cloud Storage bucket containing
the tarball with the required ASM binaries.

`_CI_ASM_IMAGE_LOCATION` is the location of the Docker images.

You can also specify a branch of this repo to use for the configuration with

`_CI_ASM_KPT_BRANCH` the name of the branch

So for example, to use gs://super-secret-bucket/asm/istio-2.0.0-asm-9.tar.gz and
gcr.io/super-secret-repo/asm as your container hub, with the master branch
config, you can invoke the script like this:

```
_CI_ASM_PKG_LOCATION=super-secret-bucket \
_CI_ASM_IMAGE_LOCATION=gcr.io/super-secret-repo/asm \
_CI_ASM_KPT_BRANCH=master \
install_asm --flag --flag...
```

## asm\_vm

This script simplifies adding GCE VM workloads to [Anthos Service Mesh] on GKE
clusters running on Google Cloud Platform.

### Prerequisites for asm\_vm

This script requires access to the following tools:

- awk
- gcloud
- grep
- jq
- kpt
- kubectl
- printf
- tail
- tr
- curl

Google Cloud Shell pre-installs these tools except `kpt`, which
you can install by using `sudo apt-get install google-cloud-sdk-kpt`.

### Running asm\_vm

There are two subcommands in `asm_vm`.

- `prepare_cluster` helps you install additional ASM components required to add
GCE VM workloads to your mesh. It also helps you verify if your cluster is ready
for adding GCE VM workloads.
- `create_gce_instance_template` creates a GCE instance template for GCE VMs to
be added to your mesh.

You can use the `--help` flag to get more details about the available arguments
for these subcommands. For example,
`./asm_vm create_gce_instance_template --help`

If the script is running as a service account and not a user, set the
SERVICE\_ACCOUNT option to the name of the service account, and
set KEY\_FILE to the file that contains the authentication credentials for that
account.

The script automatically validates dependencies and requirements before
installation. Use the `--only_validate` flag to _only_ perform
validation and stop before taking any actions with side effects.

Use the `--dry-run` flag for the script to display commands with side effects
instead of executing them, or use the `--verbose` flag to display _and_ execute
the commands. Combine the --verbose flag with --help to see extended help.
