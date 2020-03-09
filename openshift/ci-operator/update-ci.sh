#!/bin/bash
# A script that will update the mapping file in github.com/openshift/release

set -e

fail() { echo; echo "$*"; exit 1; }

# Deduce branch name and X.Y.Z version.
BRANCH=$(git rev-parse --abbrev-ref HEAD)
VERSION=$(echo $BRANCH | sed -E 's/^.*([0-9]+\.[0-9]+\.[0-9]+)|.*/\1/')
test -n "$VERSION" || fail "'$BRANCH' is not a release branch"
VER=$(echo $VERSION | sed 's/\./_/;s/\.[0-9]\+$//') # X_Y form of version

# Set up variables for important locations in the openshift/release repo.
OPENSHIFT=$(realpath "$1"); shift
test -d "$OPENSHIFT/.git" || fail "'$OPENSHIFT' is not a git repo"
MIRROR="$OPENSHIFT/core-services/image-mirroring/knative/mapping_knative_v${VER}_quay"
CONFIGDIR=$OPENSHIFT/ci-operator/config/openshift/knative-eventing
test -d "$CONFIGDIR" || fail "'$CONFIGDIR' is not a directory"

# Generate CI config files
CONFIG=$CONFIGDIR/openshift-knative-eventing-release-v$VERSION
CURDIR=$(dirname $0)
$CURDIR/generate-ci-config.sh knative-v$VERSION 4.2 > ${CONFIG}.yaml
$CURDIR/generate-ci-config.sh knative-v$VERSION 4.3 > ${CONFIG}__4.3.yaml

# Append missing lines to the mirror file.
[ -n "$(tail -c1 $MIRROR)" ] && echo >> $MIRROR # Make sure there's a newline
for IMAGE in $*; do
    NAME=knative-eventing-$(basename $IMAGE | sed 's/_/-/' | sed 's/_/-/')
    echo "Adding $NAME to mirror file"
    LINE="registry.svc.ci.openshift.org/openshift/knative-v$VERSION:$NAME quay.io/openshift-knative/$NAME:v$VERSION"
    # Add $LINE if not already present
    grep -q "^$LINE\$" $MIRROR || echo "$LINE"  >> $MIRROR
done

# Switch to openshift/release to generate PROW files
cd $OPENSHIFT
echo "Generating PROW files in $OPENSHIFT"
which docker 2> /dev/null || alias docker=podman # Use docker or podman
docker pull registry.svc.ci.openshift.org/ci/ci-operator-prowgen:latest
docker run -it -v "${PWD}/ci-operator:/ci-operator" registry.svc.ci.openshift.org/ci/ci-operator-prowgen:latest --from-dir /ci-operator/config --to-dir /ci-operator/jobs

echo "==== Changes made to $OPENSHIFT ===="
git status
echo "==== Commit changes to $OPENSHIFT and create a PR"

