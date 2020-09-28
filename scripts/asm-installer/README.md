# install\_asm
This script simplifies the installation of [Anthos Service Mesh] on GKE clusters
running on Google Cloud Platform.

[Anthos Service Mesh]: https://cloud.google.com/anthos/service-mesh/

## Prerequisites

This script requires access to the following tools:
 * awk
 * gcloud
 * grep
 * jq
 * kpt
 * kubectl
 * sed
 * tr

To verify integrity of the script download, you also need:
 * sha256sum

Google Cloud Shell pre-installs these tools except `kpt`, which
you can install by using `sudo apt-get install google-cloud-sdk-kpt`.

In addition, you need a GKE Kubernetes cluster with at least 4 nodes that use
machine types with at least 4 vCPUs. If you are not the Project Owner for
the GCP Project, you need the following Cloud IAM roles in order to run the
script successfully:
* Kubernetes Engine Admin.
* GKE Hub Admin.
* Service Usage Admin.

## Downloading the script

Download the script by using curl:
`curl -O https://storage.googleapis.com/csm-artifacts/asm/install_asm`
The sha256 of the file is also available:
`curl -O https://storage.googleapis.com/csm-artifacts/asm/install_asm.sha256`
With both files in the same directory, verify the download by using
`sha256sum -c install_asm.sha256`. If you see the message `install_asm: OK`
then verification was successful.

Optionally, you download the script by cloning this repository by using `git`.

After downloading the script, you can add the executable bit to the script or
invoke it directly by using `bash`.

## Running the script

Use the script's help flag to see detailed descriptions of its arguments:
`./install_asm --help`. Pass these arguments by using the CLI flag or
environment variables. Set the environment variables by providing the
corresponding flag name in all capital letters. Set toggle flags to 0 to
disable them or 1 to enable them.

There are five required options: CLUSTER\_NAME, CLUSTER\_LOCATION, PROJECT\_ID,
CA, and MODE. Use the first three to specify the cluster where to install
Anthos Service Mesh. Set MODE to `install` for a new installation, or `migrate`
to migrate an Istio 1.7 control plane to Anthos Service Mesh.  Set `CA` to
specify the Certificate Authority. [Mesh CA] is supported only on new
installations. Citadel is supported during migrations to help migrate workloads
safely. Google recommends migrating to Mesh CA when possible.

The script can enable the required Google Cloud APIs on your
behalf, if you can pass the `--enable_apis` flag when you run it.
Otherwise, the script will fail if they are not already enabled.

You can specify an optional YAML file to customize the IstioOperator to apply
to the Kubernetes cluster by using the OPERATOR\_OVERLAY flag. This merges the
specified file with the base Anthos Service Mesh manifest, and allows users to
install optional components at install time.

If the script is running as a service account and not a user, set the
SERVICE\_ACCOUNT option to the name of the service account, and
set KEY\_FILE to the file that contains the authentication credentials for that
account.

The script automatically validates dependencies and requirements before
installation. Use the `--only_validate` flag to _only_ perform
validation and stop before taking any actions with side effects.

Use the `--dry-run` flag for the script to display commands with side effects
instead of executing them, or use the `--verbose` flag to display _and_ execute
the commands.

The script prefixes its output with 'install\_asm' to distinguish it from the
output from other tools that it invokes.

[Mesh CA]: https://cloud.google.com/service-mesh/docs/overview#security_features

## Developer notes

You can use the scripts in the tests/ folder to test different scenarios. In
general, the scripts do the following:
* Create a 4 node GKE cluster
* Install the Google Cloud Platform microservices demo
* Install a variation of Anthos Service Mesh and verify a working gateway.

Important: You must specify a project by using the CLI, and **your project will be billed
for the used resources**. These tests attempt to clean up resources they create, but
but manually verify that all resources are deleted to avoid unexpected costs.

Warning: The cloudbuild.yaml file is for testing purposes only. Do not use this
in any project containing production resources. The Cloud Build configuration
will attempt to delete all GKE clusters older than three hours old.
