## Dev Workflow
* Checkout the repo (this assumes the basic GitHub setup already completed)
  ```
  git clone https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages.git
  ```

* Create a new branch (_outlining feature branch workflow as an example here_)
  ```
  git checkout -b username-new-feature
  ```

* Make a change, commit and push the feature branch to GH
  ```
  # make a change
  git add <some-file>
  git commit
  git push -u origin username-new-feature
  ```

* Create a pull request on GH to merge this feature branch into the `master` branch
* Resolve feedback, make the tests to pass on the PR, get the required approval on the PR
* Merge the PR
* At this point you can re-purpose the feature branch name or delete it (or leave it as is)