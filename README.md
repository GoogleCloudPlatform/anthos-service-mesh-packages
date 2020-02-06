# Anthos Service Mesh packages

This repository contains packaged configuration for setting up a GKE cluster
with [Anthos Service Mesh] features enabled.

## Setup

1.  In order to use a packages, you need to install [gcloud].
2.  Afterwards, install three components:

    ```bash
    $ gcloud components install kpt anthoscli alpha
    ```
3.  Fetch the package:

    ```bash
    # [PACKAGE] is any directory name under the repository root.
    # [OUTPUT_DIR] refers to the desired local location of the package.
    $ kpt pkg get https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages.git/[PACKAGE] [OUTPUT_DIR]

    # e.g. to get the asm package into the current folder, run the following,
    # which will create an 'asm' folder under the current folder
    $ kpt pkg get https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages.git/asm .
    ```
4.  Verify all configurable values are as desired:

    ```bash
    $ kpt cfg list-setters [ASM_FOLDER]
    # Note that by default, 'kpt get' will have populated the project and the compute zone
    # to match your current configuration.

    # If any values aren't what you want, run something like below:
    $ kpt cfg set [ASM_FOLDER] [NAME] [VALUE]

    # e.g. you can change the cluster and compute zone as follows
    $ kpt cfg set asm gcloud.core.project my-project-id
    $ kpt cfg set asm gcloud.compute.zone us-central1-b

    ```
5.  Deploy the package:

    ```bash
    $ gcloud alpha anthos apply [ASM_FOLDER]
    ```

[Anthos Service Mesh]: https://cloud.google.com/anthos/service-mesh/
[gcloud]: https://cloud.google.com/sdk/gcloud/
