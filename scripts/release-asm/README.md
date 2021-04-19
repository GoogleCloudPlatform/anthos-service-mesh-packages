# Release

This directory is used to upload various versions of the
script into the associated GCS buckets.

This is intended for Google internal use, but is included here for transparency.

## release_asm_installer
The `release_asm_installer` script is used to publish `install_asm`
and `asm_vm` scripts with all available versions. Note that not all
versions are stable: `master` and `staging` branches are published as well.

## pre_release_backfill
The `pre_release_backfill` script is used to backfill all the **stable**
versions. Now the users could download the script with the exact
version, instead of always having to download the latest release. We
believe this imporoves user experience and allows users to choose
the version they feel the most comfortable with.

## Download `install_asm` with exact versioning
For more info regarding versioning format, see this [doc](https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages/blob/master/docs/versioning.md). In short, `--version` is a flag added in ASM 1.9
and backported to previous stable versions that retrieves the version
of a script. The version follows this format:
```
{MAJOR}.{MINOR}.{POINT}-asm.{POINT}+config{REV}
```
We name the files based on this version, with `+` replaced with `-` to
avoid unexpected hexadecimal encoding in the URL during the `curl`
call made by the users. For example, a user could download the file
with version `1.9.2-asm.1+config4` like this

```shell
curl -O https://storage.googleapis.com/csm-artifacts/asm/install_asm_1.9.2-asm.1-config4
```

## Getting all stable versions
The release scripts maintains a file that contains the
mapping between the versions and the filenames `{VERSION:FILENNAME}`, and upload to the GCS bucket along with all the installer scripts.
We create this mapping so that the users don't have to manually
change the `+` to `-`. Instead, the user could curl the file named
`STABLE_VERSIONS` and display all the avaiable, stable versions:
```shell
curl https://storage.googleapis.com/csm-artifacts/asm/STABLE_VERSIONS
```

The ouput is like this:
```
1.9.2-asm.1+config4:install_asm_1.9.2-asm.1-config4
1.9.2-asm.1+config4:asm_vm_1.9.2-asm.1-config4
1.9.1-asm.1+config3:install_asm_1.9.1-asm.1-config3
1.9.1-asm.1+config3:asm_vm_1.9.1-asm.1-config3
1.9.1-asm.1+config2:install_asm_1.9.1-asm.1-config2
1.9.1-asm.1+config2:asm_vm_1.9.1-asm.1-config2
1.9.1-asm.1+config1:install_asm_1.9.1-asm.1-config1
1.9.1-asm.1+config1:asm_vm_1.9.1-asm.1-config1
...
```
