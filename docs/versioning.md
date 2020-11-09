# Versioning/Release

This document explains the versioning scheme and processes for this repo. The
intent is to make it clearer how to use tags in order to select specific
versions of the repository that are compatible with specific versions of ASM.

If the only thing you need is the format and meaning of the tags, you can stop
reading after the summary. Anything after that is a detailed description of the
config release process.

## tl;dr

If you're running ASM version x.y.z-asm.w, then you should use the tag
x.y.z-asm.w+configN with the largest N.

## Summary

Every commit into a release branch (ex. release-1.7-asm) will be tagged with
the corresponding ASM version, a +, the word "config", and a positive integer N
(ex. 1.7.3-asm3+config1) that starts with 1 and increases by one every time
configuration is updated without an update to ASM.

For example, the first commit into release-1.7-asm on version 1.7.3-asm.3 would
be 1.7.3-asm3+config1. If another commit was made before the next ASM release,
it would be 1.7.3-asm3+config2. After the next release, the number resets back
to one, so if 1.7.4-asm1 was released then the first commit in the release
branch would be 1.7.4-asm1+config1.

---

## Concepts

* **Release branch**: a branch corresponding to a specific minor version of ASM
that has the latest stable configuration for the latest minor release
* **Staging branch**: a branch corresponding to a specific minor version of ASM
that allows testing all of the configuration as one unit before merging into
the release branch
* **Tag**: an immutable pointer to a specific commit
* **Major, minor, point**: their normal meaning in [SemVer](https://semver.org/)
* **Revision**: on occasion, ASM will release an important fix without an
accompanying change in Istio's version, and this will increment the final
number in the ASM release format

## ASM version format

The format for ASM releases is: "${MAJOR}.${MINOR}.${POINT}-asm.${REV}". For
example, the third attempt at fulfilling the ASM release corresponding to Istio
1.7.3 would be 1.7.3-asm.3. For the remainder of this section, "1.7.3-asm.3"
will be used as a generic stand-in wherever an ASM version would be needed.
"1.7" will be used as a stand-in wherever the minor version would be needed.

## Processes in detail

There are two paths for a commit to make it into a release branch. One is that
a commit can land in master, and at some cadence will get rolled into
staging-1.7-asm, then release-1.7-asm. The other path is for commits that are
only relevant for a specific version, they can be merged directly into
staging-1.7-asm and then into release-1.7-asm. There are no situations where
any commits go from a release branch to any other branch, or from staging into
master.

The intention of having a staging branch at all is to allow for testing. There
is no guarantee in the master branch that all of the components support the
same versions at the same time. Having a staging branch ensures that the exact
package of configuration that will be rolled into release gets tested together.

The staging branch for the relevant version of ASM is created when the first RC
version of ASM is released internally for testing. The branch should be created
from the HEAD of master at the time, unless there is a known bad commit.

In order to reduce confusion for anyone using the repo, the release-1.7-asm
branch will not be created until ASM 1.7 is publicly released. Any development
and testing until then will happen on staging-1.7-asm, or a specialized branch
intended to be merged into staging at some point.

## Motivation for the tag format

This scheme has several desirable properties. Using tags instead of a commit
hash is more user friendly, and the format of the tag clearly associates it
with an ASM release so it will make mistakes more difficult to make. It's also
easy for a human to compare two versions of the configuration and see which one
is newer. Current methods of sorting still work with the new scheme (split on
hyphen, semver the first element and lexical sort the second). It's well-formed
enough to be verified mechanically.

## Example release

Releasing a configuration revision will follow this process:

* A pull request is created with one or more commits from staging-1.7-asm
* Review, tests, and any discussion happens on the PR
* The PR gets merged into the release branch
* An administrator pulls the release branch locally
* The administrator uses a signed, annotated git tag to tag the commit
* (Alternatively they can use GitHub's feature for verified signatures)
* If this is a new ASM release, the tag changes to that release and N resets to
1
* Otherwise, the same tag as previous release is used except increment N by one
* The administrator pushes the tag to GitHub

## Diagram

![Diagram of the process](./diagram.png?raw=true)

1. When the first staging package is available, the staging branch is created
along with associated CI/test pipelines
1. After creation, any code specific to this minor version of ASM gets
committed directly to the staging branch
1. When the first public package is made available, the release branch is
created from the last stable commit of staging
1. The first commit to the release branch is tagged with a unique tag, and
number after "config" increments for each new commit
1. When the next revision of ASM is released, the tag changes as well and the
config number resets to 1
