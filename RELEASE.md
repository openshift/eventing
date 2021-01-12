# Preparing a midstream release branch

To create a release branch for openshift/knative-eventing repo, you need to run a few steps

## Steps on the midstream repo

### Check that a remote reference to openshift and upstream exists

Like:

```bash
$ git remote -v | grep -e 'openshift\|upstream'
openshift	git@github.com:openshift/knative-eventing.git (fetch)
openshift	git@github.com:openshift/knative-eventing.git (push)
upstream	https://github.com/knative/eventing.git (fetch)
upstream	https://github.com/knative/eventing.git (push)
```

### Create a new release branch which points to upstream release branch + OpenShift specific files:
```bash
# Create a new release branch. Parameters are the upstream release tag
# and the name of the branch to create
# Usage: ./create-release-branch.sh <upstream-tag> <downstream-release-branch>
# <upstream-tag>: The tag referring the upstream release
# <downstream-release-branch>: Name of the release branch to create

UPSTREAM_TAG="v0.20.0"
MIDSTREAM_BRANCH="release-v0.20.0"
$ ./openshift/release/create-release-branch.sh $UPSTREAM_TAG $MIDSTREAM_BRANCH
```


### Push the new release branch:
```bash
# Push release branch to openshift/knative-eventing repo
$ git push openshift $MIDSTREAM_BRANCH
```

### Create a ci-operator configuration, prow job configurations and image mirroring config:

* Create a fork and clone of https://github.com/openshift/release into your `$GOPATH`
* On your `openshift/knative-eventing` root folder, run:

```bash
# Invoke CI config generation, and mirroring images

make update-ci
```

## Steps on the `openshift/release` repo:

The above `make update-ci` adds new CI configs that need to be PR'ed

## Create a PR against openshift/release repo

```bash
# Verify the changes
$ git status
On branch master
Your branch is ahead of 'origin/master' by 180 commits.
  (use "git push" to publish your local commits)

Changes not staged for commit:
  (use "git add <file>..." to update what will be committed)
  (use "git checkout -- <file>..." to discard changes in working directory)

	modified:   core-services/image-mirroring/knative/mapping_knative_v0_20_quay

Untracked files:
  (use "git add <file>..." to include in what will be committed)

	ci-operator/config/openshift/knative-eventing/openshift-knative-eventing-release-v0.20.0.yaml
	ci-operator/config/openshift/knative-eventing/openshift-knative-eventing-release-v0.20.0__46.yaml
	ci-operator/config/openshift/knative-eventing/openshift-knative-eventing-release-v0.20.0__47.yaml
	ci-operator/jobs/openshift/knative-eventing/openshift-knative-eventing-release-v0.20.0-postsubmits.yaml
	ci-operator/jobs/openshift/knative-eventing/openshift-knative-eventing-release-v0.20.0-presubmits.yaml

# Add & Commit all and push to your repo
$ git add .
$ git commit -a -m "knative-eventing release v0.20.0 setup"
$ git push

# Create pull request on https://github.com/openshift/release with your changes
# Once PR against openshift/release repo is merged, the CI is setup for release-branch
```

If there are no major changes, that should be it - you are done.

Note: Notify any changes required for this release, for e.g.: new commands, commands output update, etc. to docs team.
