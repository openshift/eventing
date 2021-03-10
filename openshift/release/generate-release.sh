#!/usr/bin/env bash

source $(dirname $0)/resolve.sh

release=$1

output_file="openshift/release/knative-eventing-ci.yaml"

if [ "$release" == "ci" ]; then
    image_prefix="registry.ci.openshift.org/openshift/knative-nightly:knative-eventing-"
    tag=""
else
    image_prefix="registry.ci.openshift.org/openshift/knative-${release}:knative-eventing-"
    tag=""
fi

# the core parts
resolve_resources config/ $output_file $image_prefix $tag

# Sugar Controller
resolve_resources config/sugar/ crd-sugar-resolved.yaml $image_prefix $tag
cat crd-sugar-resolved.yaml >> $output_file
rm crd-sugar-resolved.yaml

# InMemoryChannel CRD
resolve_resources config/channels/in-memory-channel/ crd-channel-resolved.yaml $image_prefix $tag
cat crd-channel-resolved.yaml >> $output_file
rm crd-channel-resolved.yaml

# the MT Broker:
output_file="openshift/release/knative-eventing-mtbroker-ci.yaml"
resolve_resources config/brokers/mt-channel-broker/ $output_file $image_prefix $tag
