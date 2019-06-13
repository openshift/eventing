#!/usr/bin/env bash

source $(dirname $0)/resolve.sh

release=$1

output_file="openshift/release/knative-eventing-${release}.yaml"

if [ $release = "ci" ]; then
    image_prefix="image-registry.openshift-image-registry.svc:5000/knative-eventing/knative-eventing-"
    tag=""
else
    image_prefix="quay.io/openshift-knative/knative-eventing-"
    tag=$release
fi

# the core parts
resolve_resources config/ $output_file $image_prefix $release

# in-memory-channel (ccp)
# TODO: remove in 0.8.0 - because the deprecated CCP is removed by than
resolve_resources config/provisioners/in-memory-channel/ ccp-channel-resolved.yaml $image_prefix $release
cat ccp-channel-resolved.yaml >> $output_file
rm ccp-channel-resolved.yaml

# InMemoryChannel CRD
resolve_resources config/channels/in-memory-channel/ crd-channel-resolved.yaml $image_prefix $release
cat crd-channel-resolved.yaml >> $output_file
rm crd-channel-resolved.yaml
