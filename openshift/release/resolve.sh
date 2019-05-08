#!/usr/bin/env bash

function resolve_resources(){
  local dir=$1
  local resolved_file_name=$2
  local image_prefix=$3
  local image_tag=$4

  [[ -n $image_tag ]] && image_tag=":$image_tag"

  echo "Writing resolved yaml to $resolved_file_name"

  > $resolved_file_name

  for yaml in "$dir"/*.yaml; do
    echo "---" >> $resolved_file_name
    # 1. Prefix test image references with test-
    # 2. Rewrite inmemory controller image reference separately
    # 3. Rewrite image references
    # 4. Remove comment lines
    # 5. Remove empty lines
    sed -e "s+\(.* image: \)\(github.com\)\(.*/\)\(test/\)\(.*\)+\1\2 \3\4test-\5+g" \
        -e "s+github.com/knative/eventing/cmd/broker/ingress+${image_prefix}ingress${image_tag}+" \
        -e "s+github.com/knative/eventing/cmd/broker/filter+${image_prefix}filter${image_tag}+" \
        -e "s+github.com/knative/eventing/pkg/provisioners/inmemory/controller+${image_prefix}in-memory-channel-controller${image_tag}+" \
        -e "s+github.com/knative/eventing/contrib/kafka/cmd/controller+${image_prefix}kafka-channel-controller${image_tag}+" \
        -e "s+github.com/knative/eventing/contrib/kafka/cmd/dispatcher+${image_prefix}kafka-channel-dispatcher${image_tag}+" \
        -e "s+\(.* image: \)\(github.com\)\(.*/\)\(.*\)+\1${image_prefix}\4${image_tag}+g" \
        -e '/^[ \t]*#/d' \
        -e '/^[ \t]*$/d' \
        "$yaml" >> $resolved_file_name
  done
}
