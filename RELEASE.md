# Crafting a new release

## Create a release branch for openshift/knative-eventing repo:

* Check that a remote reference to openshift and upstream exists
```bash
$ git remote -v | grep -e 'openshift\|upstream'
openshift	git@github.com:openshift/knative-eventing.git (fetch)
openshift	git@github.com:openshift/knative-eventing.git (push)
upstream	https://github.com/knative/eventing.git (fetch)
upstream	https://github.com/knative/eventing.git (push)
```

* Create a new release branch which points to upstream release branch + OpenShift specific files:
```bash
# Create a new release branch. Parameters are the upstream release tag
# and the name of the branch to create
# Usage: ./create-release-branch.sh <upstream-tag> <downstream-release-branch>
# <upstream-tag>: The tag referring the upstream release
# <downstream-release-branch>: Name of the release branch to create
$ ./create-release-branch.sh v0.15.0 release-v0.15.0
```

* Update the references to the CI release yaml files, matching the newly created branch:

Replace [this line](https://github.com/matzew/eventing/blob/valid_ci_generation/openshift/olm/knative-eventing.catalogsource.yaml#L698), with something like:

```yaml
                        - --filename=https://raw.githubusercontent.com/openshift/knative-eventing/release-v0.15.0/openshift/release/knative-eventing-ci.yaml,https://raw.githubusercontent.com/openshift/knative-eventing/release-v0.15.0/openshift/release/knative-eventing-channelbroker-ci.yaml,https://raw.githubusercontent.com/openshift/knative-eventing/release-v0.15.0/openshift/release/knative-eventing-mtbroker-ci.yaml
```


* Push the new release branch:
```bash
# Push release branch to openshift/knative-eventing repo
$ git push openshift release-v0.14.0
```

## Create a ci-operator configuration, prow job configurations and image mirroring config:

* Create a fork and clone of https://github.com/openshift/release into your `$GOPATH`
* On your `openshift/knative-eventing` root folder, run:
```bash
# Invoke CI config generation, and mirroring images
make update-ci
```

## Create a PR against openshift/release repo for CI setup of release branch using configs generated above:
```bash
# Verify the changes
$ git status
On branch master
Your branch is ahead of 'origin/master' by 180 commits.
  (use "git push" to publish your local commits)

Changes not staged for commit:
  (use "git add <file>..." to update what will be committed)
  (use "git checkout -- <file>..." to discard changes in working directory)

	modified:   core-services/image-mirroring/knative/mapping_knative_v0_15_quay

Untracked files:
  (use "git add <file>..." to include in what will be committed)

	ci-operator/config/openshift/knative-eventing/openshift-knative-eventing-release-v0.14.2.yaml
	ci-operator/config/openshift/knative-eventing/openshift-knative-eventing-release-v0.14.2__4.4.yaml
	ci-operator/config/openshift/knative-eventing/openshift-knative-eventing-release-v0.14.2__4.5.yaml
	ci-operator/jobs/openshift/knative-eventing/openshift-knative-eventing-release-v0.14.2-postsubmits.yaml
	ci-operator/jobs/openshift/knative-eventing/openshift-knative-eventing-release-v0.14.2-presubmits.yaml

# Add & Commit all and push to your repo
$ git add .
$ git commit -a -m "knative-eventing release v0.15.0 setup"
$ git push

# Create pull request on https://github.com/openshift/release with your changes
# Once PR against openshift/release repo is merged, the CI is setup for release-branch
```

## Once the changes to release branch is finalized, and we are ready for QA, create tag and push:
```bash
$ git tag openshift-v0.14.0
$ git push openshift openshift-v0.14.0
```

Note: Notify any changes required for this release, for e.g.: new commands, commands output update, etc. to docs team.
