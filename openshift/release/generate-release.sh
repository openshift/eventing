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

resolve_resources config/ $output_file $image_prefix $release

# in-memory-channel
resolve_resources config/provisioners/in-memory-channel/ channel-resolved.yaml $image_prefix $release
cat channel-resolved.yaml >> $output_file
rm channel-resolved.yaml
