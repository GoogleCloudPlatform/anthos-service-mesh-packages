# ASM Installer

[Anthos Service Mesh]: https://cloud.google.com/anthos/service-mesh/

## Downloading asmcli

To verify integrity of the script download, you need:

- sha256sum

Download the `asmcli` script by using curl:
`curl -O https://storage.googleapis.com/csm-artifacts/asm/asmcli`

The sha256 of the file is also available:
`curl -O https://storage.googleapis.com/csm-artifacts/asm/asmcli.sha256`

With both files in the same directory, verify the download by using
`sha256sum -c asmcli.sha256`. If you see the message `asmcli: OK`
then verification was successful.

Optionally, you download the script by cloning this repository by using `git`.

After downloading the script, you can add the executable bit to the script or
invoke it directly by using `bash`.

### Prerequisites

This script requires access to the following tools:

- awk
- gcloud
- grep
- jq
- kubectl
- sed
- tr

In addition, you need a GKE Kubernetes cluster with at least 8 vCPUs that use
machine types with at least 4 vCPUs. If you are not the Project Owner for
the GCP Project, you need the following Cloud IAM roles in order to run the
script successfully:

- Kubernetes Engine Admin.
- GKE Hub Admin.
- Service Usage Admin.

### Running asmcli

Use the script's help flag to see detailed descriptions of its arguments:
`./asmcli --help`. Pass these arguments by using the CLI flag or
environment variables. Set the environment variables by providing the
corresponding flag name in all capital letters. Set toggle flags to 0 to
disable them or 1 to enable them. Descriptions of arguments from the usage
prompt of the script are always more correct than any other source.

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

The script automatically validates dependencies and requirements before
installation. Use the `--only_validate` flag to _only_ perform
validation and stop before taking any actions with side effects.

Use the `--dry-run` flag for the script to display commands with side effects
instead of executing them, or use the `--verbose` flag to display _and_ execute
the commands. Combine the --verbose flag with --help to see extended help.

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
