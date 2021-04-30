## Dev Workflow

* Create a fork of `https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages.git`
* Make a change, commit and push the changes in the forked repo to GH
* Run some tests locally to make sure your pull request won't break anything else 
(see below a list of commands you could run)
* Create a pull request on GH to merge the updates in the fork to the official repo
* Resolve feedback, make the tests to pass on the PR, get the required approval on the PR
* And eventually one of the maintainers will merge the PR


Here are some tests you could run locally:

If you add a new file in `asm/istio/options/` folder, run:
```
./install_asm \
  --custom_overlay asm/istio/options/YOUR-FILE.yaml
```

If you add or update a setter in the `asm/Kptfile`, run:
```
# Retrieve the associated package of your own branch:
kpt pkg get https://github.com/YOUR-GH-ACCOUNT/anthos-service-mesh-packages.git/asm@THE-NAME-OF-YOUR-BRANCH .
# Here you should see some "automatically set XX field(s)" in the output.

# Set a new value to your setter:
kpt cfg set YOUR-SETTER ITS-VALUE

# List of the setters is not showing an empty list:
kpt cfg list-setters asm
```