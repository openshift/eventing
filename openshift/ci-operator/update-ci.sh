#!/bin/bash
# A script that will update the mapping file in github.com/openshift/release

set -e

fail() { echo; echo "$*"; exit 1; }

# Deduce branch name and X.Y.Z version.
BRANCH=$(git rev-parse --abbrev-ref HEAD)
VERSION=$(echo $BRANCH | sed -E 's/^.*(v[0-9]+\.[0-9]+\.[0-9]+|next)|.*/\1/')
test -n "$VERSION" || fail "'$BRANCH' is not a release branch"

# Set up variables for important locations in the openshift/release repo.
OPENSHIFT=$(realpath "$1"); shift
test -d "$OPENSHIFT/.git" || fail "'$OPENSHIFT' is not a git repo"
CONFIGDIR=$OPENSHIFT/ci-operator/config/openshift/knative-eventing
test -d "$CONFIGDIR" || fail "'$CONFIGDIR' is not a directory"

# Generate CI config files
CONFIG=$CONFIGDIR/openshift-knative-eventing-release-$VERSION
CURDIR=$(dirname $0)
$CURDIR/generate-ci-config.sh knative-$VERSION 4.6 > ${CONFIG}__46.yaml
$CURDIR/generate-ci-config.sh knative-$VERSION 4.7 true > ${CONFIG}__47.yaml

# Append missing lines to the mirror file.
VER=$(echo $VERSION | sed 's/\./_/;s/\.[0-9]\+$//') # X_Y form of version
MIRROR="$OPENSHIFT/core-services/image-mirroring/knative/mapping_knative_${VER}_quay"
[ -n "$(tail -c1 $MIRROR)" ] && echo >> $MIRROR # Make sure there's a newline
test_images=$(find ./openshift/ci-operator/knative-test-images -mindepth 1 -maxdepth 1 -type d | LC_COLLATE=posix sort)
for IMAGE in $test_images; do
    NAME=knative-eventing-test-$(basename $IMAGE | sed 's/_/-/' | sed 's/_/-/' | sed 's/[_.]/-/' | sed 's/[_.]/-/' | sed 's/v0/upgrade-v0/')

    echo "Adding $NAME to mirror file as $VERSION tag"
    LINE="registry.ci.openshift.org/openshift/knative-$VERSION:$NAME quay.io/openshift-knative/${NAME/knative-eventing-test-/}:$VERSION"
    # Add $LINE if not already present
    grep -q "^$LINE\$" $MIRROR || echo "$LINE"  >> $MIRROR

    VER=$(echo $VER | sed 's/\_/./')
    echo "Adding $NAME to mirror file as $VER tag"
    LINE="registry.ci.openshift.org/openshift/knative-$VERSION:$NAME quay.io/openshift-knative/${NAME/knative-eventing-test-/}:$VER"
    # Add $LINE if not already present
    grep -q "^$LINE\$" $MIRROR || echo "$LINE"  >> $MIRROR
done

# Switch to openshift/release to generate PROW files
cd $OPENSHIFT
echo "Generating PROW files in $OPENSHIFT"
make jobs
make ci-operator-config
echo "==== Changes made to $OPENSHIFT ===="
git status
echo "==== Commit changes to $OPENSHIFT and create a PR"
