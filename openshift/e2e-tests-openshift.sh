#!/usr/bin/env bash

source $(dirname ${BASH_SOURCE})/../vendor/github.com/knative/test-infra/scripts/e2e-tests.sh
source $(dirname ${BASH_SOURCE})/release/resolve.sh
source $(dirname ${BASH_SOURCE})/e2e-helpers.sh

set -x

scale_up_workers || exit 1

readTestFiles || exit 1

create_test_namespace || exit 1

failed=0

(( !failed )) && install_strimzi || failed=1

(( !failed )) && install_knative_serving || failed=1

(( !failed )) && install_knative_eventing || failed=1

(( !failed )) && create_test_resources

if [[ $TEST_ORIGIN_CONFORMANCE == true ]]; then
  (( !failed )) && run_origin_e2e || failed=1
fi

(( !failed )) && run_e2e_tests || failed=1

(( failed )) && dump_cluster_state

teardown

(( failed )) && exit 1

success
