#!/usr/bin/env bash

# shellcheck disable=SC1090
source "$(dirname "$0")/../vendor/knative.dev/hack/e2e-tests.sh"
source "$(dirname "$0")/e2e-common.sh"

set -Eeuox pipefail

if [ -n "${TEMPLATE:-}" ]; then
  export TEST_IMAGE_TEMPLATE="$TEMPLATE"
elif [ -n "${DOCKER_REPO_OVERRIDE:-}" ]; then
  export TEST_IMAGE_TEMPLATE="${DOCKER_REPO_OVERRIDE}/{{.Name}}"
elif [ -n "${BRANCH:-}" ]; then
  export TEST_IMAGE_TEMPLATE="registry.svc.ci.openshift.org/openshift/${BRANCH}:knative-eventing-test-{{.Name}}"
else
  export TEST_IMAGE_TEMPLATE="registry.svc.ci.openshift.org/openshift/knative-nightly:knative-eventing-test-{{.Name}}"
fi

env

failed=0

(( !failed )) && run_e2e_tests "${TEST:-}" || failed=1

(( failed )) && dump_cluster_state

(( failed )) && exit 1

success
