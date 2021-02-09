#!/usr/bin/env bash

export EVENTING_NAMESPACE="${EVENTING_NAMESPACE:-knative-eventing}"
export SYSTEM_NAMESPACE=$EVENTING_NAMESPACE
export ZIPKIN_NAMESPACE=$EVENTING_NAMESPACE
export KNATIVE_DEFAULT_NAMESPACE=$EVENTING_NAMESPACE
export CONFIG_TRACING_CONFIG="test/config/config-tracing.yaml"

function scale_up_workers(){
  local cluster_api_ns="openshift-machine-api"

  oc get machineset -n ${cluster_api_ns} --show-labels

  # Get the name of the first machineset that has at least 1 replica
  local machineset
  machineset=$(oc get machineset -n ${cluster_api_ns} -o custom-columns="name:{.metadata.name},replicas:{.spec.replicas}" | grep " 1" | head -n 1 | awk '{print $1}')
  # Bump the number of replicas to 6 (+ 1 + 1 == 8 workers)
  oc patch machineset -n ${cluster_api_ns} "${machineset}" -p '{"spec":{"replicas":6}}' --type=merge
  wait_until_machineset_scales_up ${cluster_api_ns} "${machineset}" 6
}

# Waits until the machineset in the given namespaces scales up to the
# desired number of replicas
# Parameters: $1 - namespace
#             $2 - machineset name
#             $3 - desired number of replicas
function wait_until_machineset_scales_up() {
  echo -n "Waiting until machineset $2 in namespace $1 scales up to $3 replicas"
  for _ in {1..150}; do  # timeout after 15 minutes
    local available
    available=$(oc get machineset -n "$1" "$2" -o jsonpath="{.status.availableReplicas}")
    if [[ ${available} -eq $3 ]]; then
      echo -e "\nMachineSet $2 in namespace $1 successfully scaled up to $3 replicas"
      return 0
    fi
    echo -n "."
    sleep 6
  done
  echo - "Error: timeout waiting for machineset $2 in namespace $1 to scale up to $3 replicas"
  return 1
}

# Loops until duration (car) is exceeded or command (cdr) returns non-zero
function timeout_non_zero() {
  SECONDS=0; TIMEOUT=$1; shift
  while eval $*; do
    sleep 5
    [[ $SECONDS -gt $TIMEOUT ]] && echo "ERROR: Timed out" && return 1
  done
  return 0
}

function install_tracing {
  deploy_zipkin
  enable_eventing_tracing
}

function deploy_zipkin {
  logger.info "Installing Zipkin in namespace ${ZIPKIN_NAMESPACE}"
  cat <<EOF | oc apply -f - || return $?
apiVersion: v1
kind: Service
metadata:
  name: zipkin
  namespace: ${ZIPKIN_NAMESPACE}
spec:
  type: NodePort
  ports:
  - name: http
    port: 9411
  selector:
    app: zipkin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zipkin
  namespace: ${ZIPKIN_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: zipkin
  template:
    metadata:
      labels:
        app: zipkin
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      containers:
      - name: zipkin
        image: docker.io/openzipkin/zipkin:2.13.0
        ports:
        - containerPort: 9411
        env:
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              apiVersion: v1
              fieldPath: metadata.namespace
        resources:
          limits:
            memory: 1000Mi
          requests:
            memory: 256Mi
---
EOF

  logger.info "Waiting until Zipkin is available"
  kubectl wait deployment --all --timeout=600s --for=condition=Available -n ${ZIPKIN_NAMESPACE} || return 1
}

function enable_eventing_tracing {
  header_text "Configuring tracing for Eventing"

  cat <<EOF | oc apply -f - || return $?
apiVersion: v1
kind: ConfigMap
metadata:
  name: config-tracing
  namespace: ${EVENTING_NAMESPACE}
data:
  enable: "true"
  zipkin-endpoint: "http://zipkin.${ZIPKIN_NAMESPACE}.svc.cluster.local:9411/api/v2/spans"
  sample-rate: "1.0"
  debug: "true"
EOF
}

function install_serverless(){
  header "Installing Serverless Operator"
  local operator_dir=/tmp/serverless-operator
  local failed=0
  git clone --branch release-1.11 https://github.com/openshift-knative/serverless-operator.git $operator_dir
  # unset OPENSHIFT_BUILD_NAMESPACE (old CI) and OPENSHIFT_CI (new CI) as its used in serverless-operator's CI
  # environment as a switch to use CI built images, we want pre-built images of k-s-o and k-o-i
  unset OPENSHIFT_BUILD_NAMESPACE
  unset OPENSHIFT_CI
  pushd $operator_dir
  INSTALL_EVENTING="false" ./hack/install.sh && header "Serverless Operator installed successfully" || failed=1
  popd
  return $failed
}

function install_knative_eventing(){
  header "Installing Knative Eventing"

  cat openshift/release/knative-eventing-ci.yaml > ci
  cat openshift/release/knative-eventing-mtbroker-ci.yaml >> ci

  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-controller|${IMAGE_FORMAT//\$\{component\}/knative-eventing-controller}|g"                               ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-ping|${IMAGE_FORMAT//\$\{component\}/knative-eventing-ping}|g"                                           ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-mtping|${IMAGE_FORMAT//\$\{component\}/knative-eventing-mtping}|g"                                       ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-apiserver-receive-adapter|${IMAGE_FORMAT//\$\{component\}/knative-eventing-apiserver-receive-adapter}|g" ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-webhook|${IMAGE_FORMAT//\$\{component\}/knative-eventing-webhook}|g"                                     ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-channel-controller|${IMAGE_FORMAT//\$\{component\}/knative-eventing-channel-controller}|g"               ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-channel-dispatcher|${IMAGE_FORMAT//\$\{component\}/knative-eventing-channel-dispatcher}|g"               ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-mtbroker-ingress|${IMAGE_FORMAT//\$\{component\}/knative-eventing-mtbroker-ingress}|g"                   ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-mtbroker-filter|${IMAGE_FORMAT//\$\{component\}/knative-eventing-mtbroker-filter}|g"                     ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-mtchannel-broker|${IMAGE_FORMAT//\$\{component\}/knative-eventing-mtchannel-broker}|g"                   ci
  sed -i -e "s|registry.svc.ci.openshift.org/openshift/knative-.*:knative-eventing-sugar-controller|${IMAGE_FORMAT//\$\{component\}/knative-eventing-sugar-controller}|g"                   ci

  oc apply -f ci || return 1
  rm ci

  # Wait for 5 pods to appear first
  timeout_non_zero 900 '[[ $(oc get pods -n $EVENTING_NAMESPACE --no-headers | wc -l) -lt 5 ]]' || return 1
  wait_until_pods_running $EVENTING_NAMESPACE || return 1

  # Assert that there are no images used that are not CI images (which should all be using the $INTERNAL_REGISTRY)
  # (except for the knative-eventing-operator)
  #oc get pod -n knative-eventing -o yaml | grep image: | grep -v knative-eventing-operator | grep -v ${INTERNAL_REGISTRY} && return 1 || true
}

function uninstall_knative_eventing(){
  header "Uninstalling Knative Eventing"

  cat openshift/release/knative-eventing-ci.yaml > ci
  cat openshift/release/knative-eventing-mtbroker-ci.yaml >> ci

  oc delete -f ci --ignore-not-found=true || return 1
  rm ci
}

function run_e2e_tests(){
  header "Running E2E tests with Multi Tenant Channel Based Broker"
  oc get ns ${SYSTEM_NAMESPACE} 2>/dev/null || SYSTEM_NAMESPACE="knative-eventing"
  sed "s/namespace: ${KNATIVE_DEFAULT_NAMESPACE}/namespace: ${SYSTEM_NAMESPACE}/g" ${CONFIG_TRACING_CONFIG} | oc replace -f -
  local test_name="${1:-}"
  local run_command=""
  local failed=0
  local channels=messaging.knative.dev/v1beta1:Channel,messaging.knative.dev/v1beta1:InMemoryChannel,messaging.knative.dev/v1:Channel,messaging.knative.dev/v1:InMemoryChannel
  local sources=sources.knative.dev/v1alpha2:ApiServerSource,sources.knative.dev/v1alpha2:ContainerSource,sources.knative.dev/v1alpha2:PingSource

  local common_opts=" -channels=$channels -sources=$sources --kubeconfig $KUBECONFIG --imagetemplate $TEST_IMAGE_TEMPLATE"
  if [ -n "$test_name" ]; then
      local run_command="-run ^(${test_name})$"
  fi

  oc -n knative-eventing set env deployment/mt-broker-controller BROKER_INJECTION_DEFAULT=true || return 1
  wait_until_pods_running $EVENTING_NAMESPACE || return 2

  go_test_e2e -timeout=50m -parallel=20 ./test/e2e \
    "$run_command" \
    -brokerclass=MTChannelBasedBroker \
    $common_opts || failed=$?

  return $failed
}

function run_conformance_tests(){
  header "Running Conformance tests with Multi Tenant Channel Based Broker"
  oc get ns ${SYSTEM_NAMESPACE} 2>/dev/null || SYSTEM_NAMESPACE="knative-eventing"
  sed "s/namespace: ${KNATIVE_DEFAULT_NAMESPACE}/namespace: ${SYSTEM_NAMESPACE}/g" ${CONFIG_TRACING_CONFIG} | oc replace -f -
  local test_name="${1:-}"
  local run_command=""
  local failed=0
  local channels=messaging.knative.dev/v1beta1:Channel,messaging.knative.dev/v1beta1:InMemoryChannel,messaging.knative.dev/v1:Channel,messaging.knative.dev/v1:InMemoryChannel
  local sources=sources.knative.dev/v1alpha2:ApiServerSource,sources.knative.dev/v1alpha2:ContainerSource,sources.knative.dev/v1alpha2:PingSource

  local common_opts=" -channels=$channels -sources=$sources --kubeconfig $KUBECONFIG --imagetemplate $TEST_IMAGE_TEMPLATE"
  if [ -n "$test_name" ]; then
      local run_command="-run ^(${test_name})$"
  fi

  oc -n knative-eventing set env deployment/mt-broker-controller BROKER_INJECTION_DEFAULT=true || return 1
  wait_until_pods_running $EVENTING_NAMESPACE || return 2

  go_test_e2e -timeout=30m -parallel=12 ./test/conformance \
    "$run_command" \
    -brokerclass=MTChannelBasedBroker \
    $common_opts || failed=$?

  return $failed
}
