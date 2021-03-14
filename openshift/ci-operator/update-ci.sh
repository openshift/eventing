#!/bin/bash
# A script that will update the mapping file in github.com/openshift/release

set -e
readonly TMPDIR=$(mktemp -d knativeEventingPeriodicReporterXXXX -p /tmp/)

fail() { echo; echo "$*"; exit 1; }

cat >> "$TMPDIR"/reporterConfig <<EOF
  reporter_config:
    slack:
      channel: '#knative-eventing'
      job_states_to_report:
      - success
      - failure
      - error
      report_template: '{{if eq .Status.State "success"}} :rainbow: Job *{{.Spec.Job}}* ended with *{{.Status.State}}*. <{{.Status.URL}}|View logs> :rainbow: {{else}} :volcano: Job *{{.Spec.Job}}* ended with *{{.Status.State}}*. <{{.Status.URL}}|View logs> :volcano: {{end}}'
EOF

# Deduce branch name and X.Y.Z version.
BRANCH=$(git rev-parse --abbrev-ref HEAD)
VERSION=$(echo $BRANCH | sed -E 's/^.*(v[0-9]+\.[0-9]+\.[0-9]+|next)|.*/\1/')
test -n "$VERSION" || fail "'$BRANCH' is not a release branch"

# Set up variables for important locations in the openshift/release repo.
OPENSHIFT=$(realpath "$1"); shift
test -d "$OPENSHIFT/.git" || fail "'$OPENSHIFT' is not a git repo"
CONFIGDIR=$OPENSHIFT/ci-operator/config/openshift/knative-eventing
test -d "$CONFIGDIR" || fail "'$CONFIGDIR' is not a directory"
PERIODIC_CONFIGDIR=$OPENSHIFT/ci-operator/jobs/openshift/knative-eventing
test -d "$PERIODIC_CONFIGDIR" || fail "'$PERIODIC_CONFIGDIR' is not a directory"

# Generate CI config files
CONFIG=$CONFIGDIR/openshift-knative-eventing-release-$VERSION
PERIODIC_CONFIG=$PERIODIC_CONFIGDIR/openshift-knative-eventing-release-$VERSION-periodics.yaml
CURDIR=$(dirname $0)
$CURDIR/generate-ci-config.sh knative-$VERSION 4.7 > ${CONFIG}__47.yaml

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
# We have to do this manually, see: https://docs.ci.openshift.org/docs/how-tos/notification/
echo "==== Adding reporter_config to periodics ===="
# These version MUST match the ocp version we used above
for OCP_VERSION in 47; do
    sed -i "/  name: periodic-ci-openshift-knative-eventing-release-${VERSION}-${OCP_VERSION}-e2e-aws-ocp-${OCP_VERSION}-continuous\n  spec:/ r $TMPDIR/reporterConfig" "$PERIODIC_CONFIG"
done
echo "==== Changes made to $OPENSHIFT ===="
git status
echo "==== Commit changes to $OPENSHIFT and create a PR"
