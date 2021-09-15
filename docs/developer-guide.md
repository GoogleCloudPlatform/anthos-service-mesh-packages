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

To maintain the most up-to-date script at all times, we require the merged script to be committed to the repo.
The merged script should either be moved or copied to the package root `asmcli/` and commit manually.
We provide a simple script to perform the merge and copy for you, simply run:
```shell
./scripts/release-asm/precommit
```
and commit the changes. 

**Note**: the merged/generated `asmcli` should not be manually modified ever. In case of merge conflicts,
fix the individual files, re-generate the standalone script and add it to the git.

## During Development
* **Important**: make sure all global variables and functions are `readonly` to prevent unexpected overwriting.
* Don't add `#!/usr/bin/env bash` or equivalent lines to any modules/files. This line will be added during the compilation.
* Put all code in functions. The merge logic will add the call to `main`. In other words, don't add any entry point to actually
execute the script.


## Writing Tests
We integrated [`bats`](https://github.com/bats-core/bats-core) as our
testing system. To add tests, read the
[official documentation](https://bats-core.readthedocs.io/en/latest/)
and update/add `*.bats` files to the `asmcli/tests` folder.
If there's any set-up that could be shared among tests, update
`unit_test_common.bash` in the test folder.

The `:test` target will by default run all the tests. If you want
finer-grained test targets, add new `sh_test` targets to `BUILD` and
attach the relevant test files.


## Running Tests
To install `bats`, simply run
```shell
npm install
```
in the pacakge root directory. You might need to install [`npm`](https://nodejs.org/en/knowledge/getting-started/npm/what-is-npm/) first.
To run tests,
```shell
bazel test $TEST_TARGET --test_output=all
```
or to have the tests streamed
```shell
bazel test $TEST_TARGET --test_output=streamed
```
