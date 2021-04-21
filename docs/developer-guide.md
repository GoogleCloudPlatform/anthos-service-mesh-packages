## Dev Workflow

* Create a fork of `https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages.git`
* Make a change, commit and push the changes in the forked repo to GH
* Create a pull request on GH to merge the updates in the fork to the official repo
* Resolve feedback, make the tests to pass on the PR, get the required approval on the PR
* Merge the PR

## Merge the modules

To gather all the pieces together and genereate the standalone `asmcli` script, we introduce [Bazel](https://www.bazel.build/) as the build system.
Please follow the official installation steps to have Bazel installed.
To merge the scripts, run:
```shell
bazel build merge
```
The merged script will be in `bazel-bin/`. 

To cleanup:
```shell
bazel clean --expunge
```
or to cleanup asynchronously:
```shell
bazel clean --expunge_async
```

## During Development
* **Important**: make sure all global variables and functions are `readonly` to prevent unexpected overwriting. 
* Don't add `#!/usr/bin/env bash` or equivalanet lines to any modules/files. This line will be added during the compilation.
* Put all code in functions. The merge logic will add the call to `main`. In other words, don't add any entry point to actually execute
the script.
