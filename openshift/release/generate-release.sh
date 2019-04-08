#!/usr/bin/env bash

source $(dirname $0)/resolve.sh

release=$1

quay_image_prefix="quay.io/openshift-knative/knative-eventing-"
output_file="openshift/release/knative-eventing-${release}.yaml"

resolve_resources config/ $output_file $quay_image_prefix $release
resolve_resources config/provisioners/in-memory-channel/ channel-resolved.yaml $quay_image_prefix $release
cat channel-resolved.yaml >> $output_file