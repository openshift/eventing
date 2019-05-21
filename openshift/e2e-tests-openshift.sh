#!/bin/sh 

source $(dirname $0)/../vendor/github.com/knative/test-infra/scripts/e2e-tests.sh
source $(dirname $0)/release/resolve.sh
source $(dirname $0)/kubecon-demo.sh

set -x

readonly BUILD_VERSION=v0.4.0
readonly BUILD_RELEASE=https://github.com/knative/build/releases/download/${BUILD_VERSION}/build.yaml
readonly MAISTRA_VERSION="0.10"
readonly SERVING_VERSION=v0.5.1
readonly SERVING_RELEASE=https://github.com/knative/serving/releases/download/${SERVING_VERSION}/serving.yaml
# We use nightly, to match the fact we do build here the latest from EVENTING
readonly EVENTING_VERSION=v0.6.0
readonly EVENTING_SOURCES_RELEASE=https://github.com/knative/eventing-sources/releases/download/${EVENTING_VERSION}/eventing-sources.yaml

readonly K8S_CLUSTER_OVERRIDE=$(oc config current-context | awk -F'/' '{print $2}')
readonly API_SERVER=$(oc config view --minify | grep server | awk -F'//' '{print $2}' | awk -F':' '{print $1}')
readonly INTERNAL_REGISTRY="${INTERNAL_REGISTRY:-"image-registry.openshift-image-registry.svc:5000"}"
readonly USER=$KUBE_SSH_USER #satisfy e2e_flags.go#initializeFlags()
readonly OPENSHIFT_REGISTRY="${OPENSHIFT_REGISTRY:-"registry.svc.ci.openshift.org"}"
readonly INSECURE="${INSECURE:-"false"}"
readonly TEST_ORIGIN_CONFORMANCE="${TEST_ORIGIN_CONFORMANCE:-"false"}"
readonly SERVING_NAMESPACE=knative-serving
readonly EVENTING_NAMESPACE=knative-eventing
readonly TARGET_IMAGE_PREFIX="$INTERNAL_REGISTRY/$EVENTING_NAMESPACE/knative-eventing-"

env

# Loops until duration (car) is exceeded or command (cdr) returns non-zero
function timeout_non_zero() {
  SECONDS=0; TIMEOUT=$1; shift
  while eval $*; do
    sleep 5
    [[ $SECONDS -gt $TIMEOUT ]] && echo "ERROR: Timed out" && return 1
  done
  return 0
}

function install_istio(){
  header "Installing Istio"

  # Install the Maistra Operator
  oc new-project istio-operator
  oc new-project istio-system
  oc apply -n istio-operator -f https://raw.githubusercontent.com/Maistra/istio-operator/maistra-${MAISTRA_VERSION}/deploy/maistra-operator.yaml

  # Wait until the Operator pod is up and running
  wait_until_pods_running istio-operator || return 1

  # Deploy Istio
  cat <<EOF | oc apply -f -
apiVersion: istio.openshift.com/v1alpha3
kind: ControlPlane
metadata:
  name: basic-install
spec:
  istio:
    global:
      # use community images
      hub: "maistra"
      tag: ${MAISTRA_VERSION}.0
      proxy:
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 128Mi
    sidecarInjectorWebhook:
      enabled: false
    gateways:
      istio-egressgateway:
        autoscaleEnabled: false
      istio-ingressgateway:
        autoscaleEnabled: false
        ior_enabled: false
    mixer:
      policy:
        autoscaleEnabled: false
      telemetry:
        autoscaleEnabled: false
        resources:
          requests:
            cpu: 100m
            memory: 1G
          limits:
            cpu: 200m
            memory: 2G
    pilot:
      autoscaleEnabled: false
    kiali:
      enabled: false
    tracing:
      enabled: false
EOF

  # Wait until at least the Istio ControlPlane is installed
  timeout_non_zero 900 '[[ $(oc get ControlPlane/basic-install --template="{{range .status.conditions}}{{printf \"%s=%s, reason=%s, message=%s\n\n\" .type .status .reason .message}}{{end}}" | grep -c Installed=True) -eq 0 ]]' || return 1

  # Scale down unused services deployed by the istio operator
  oc scale -n istio-system --replicas=0 deployment/grafana
  
  header "Istio Installed successfully"
}

function install_knative_build(){
  header "Installing Knative Build"

  oc adm policy add-scc-to-user anyuid -z build-controller -n knative-build
  oc adm policy add-cluster-role-to-user cluster-admin -z build-controller -n knative-build
  oc adm policy add-cluster-role-to-user cluster-admin -z build-pipeline-controller -n knative-build-pipeline

  oc apply -f $BUILD_RELEASE

  wait_until_pods_running knative-build || return 1
  header "Knative Build installed successfully"
}


function install_knative_serving(){
  header "Installing Knative Serving"

  # Grant the necessary privileges to the service accounts Knative will use:
  oc adm policy add-scc-to-user anyuid -z controller -n knative-serving
  oc adm policy add-scc-to-user anyuid -z autoscaler -n knative-serving
  oc adm policy add-cluster-role-to-user cluster-admin -z controller -n knative-serving

  curl -L $SERVING_RELEASE \
  | sed 's/LoadBalancer/NodePort/' \
  | oc apply --filename -

  enable_knative_interaction_with_registry

  echo ">> Patching Istio"
  for gateway in istio-ingressgateway cluster-local-gateway istio-egressgateway; do
    if kubectl get svc -n istio-system ${gateway} > /dev/null 2>&1 ; then
      kubectl patch hpa -n istio-system ${gateway} --patch '{"spec": {"maxReplicas": 1}}'
      kubectl set resources deploy -n istio-system ${gateway} \
        -c=istio-proxy --requests=cpu=50m 2> /dev/null
    fi
  done

  # There are reports of Envoy failing (503) when istio-pilot is overloaded.
  # We generously add more pilot instances here to verify if we can reduce flakes.
  if kubectl get hpa -n istio-system istio-pilot 2>/dev/null; then
    # If HPA exists, update it.  Since patching will return non-zero if no change
    # is made, we don't return on failure here.
    kubectl patch hpa -n istio-system istio-pilot \
      --patch '{"spec": {"minReplicas": 3, "maxReplicas": 10, "targetCPUUtilizationPercentage": 60}}' \
      `# Ignore error messages to avoid causing red herrings in the tests` \
      2>/dev/null
  else
    # Some versions of Istio doesn't provide an HPA for pilot.
    kubectl autoscale -n istio-system deploy istio-pilot --min=3 --max=10 --cpu-percent=60 || return 1
  fi

  wait_until_pods_running knative-serving || return 1
  wait_until_service_has_external_ip istio-system istio-ingressgateway || fail_test "Ingress has no external IP"
  wait_until_hostname_resolves $(kubectl get svc -n istio-system istio-ingressgateway -o jsonpath="{.status.loadBalancer.ingress[0].hostname}")

  header "Knative Serving installed successfully"
}

function install_knative_eventing(){
  header "Installing Knative Eventing"

  # Create knative-eventing namespace, needed for imagestreams
  oc create namespace $EVENTING_NAMESPACE

  # Grant the necessary privileges to the service accounts Knative will use:
  oc annotate clusterrolebinding.rbac cluster-admin 'rbac.authorization.kubernetes.io/autoupdate=false' --overwrite
  oc annotate clusterrolebinding.rbac cluster-admins 'rbac.authorization.kubernetes.io/autoupdate=false' --overwrite

  oc adm policy add-scc-to-user anyuid -z eventing-controller -n $EVENTING_NAMESPACE
  oc adm policy add-scc-to-user anyuid -z eventing-webhook -n $EVENTING_NAMESPACE
  #oc adm policy add-scc-to-user privileged -z eventing-webhook -n $EVENTING_NAMESPACE
  oc adm policy add-scc-to-user anyuid -z in-memory-channel-dispatcher -n $EVENTING_NAMESPACE
  oc adm policy add-scc-to-user anyuid -z in-memory-channel-controller -n $EVENTING_NAMESPACE

  resolve_resources config/ eventing-resolved.yaml $TARGET_IMAGE_PREFIX

  tag_core_images eventing-resolved.yaml

  oc apply -f eventing-resolved.yaml

  oc adm policy add-cluster-role-to-user cluster-admin -z eventing-controller -n $EVENTING_NAMESPACE
  #oc adm policy add-cluster-role-to-user cluster-admin -z eventing-webhook -n $EVENTING_NAMESPACE
  oc adm policy add-cluster-role-to-user cluster-admin -z in-memory-channel-dispatcher -n $EVENTING_NAMESPACE
  oc adm policy add-cluster-role-to-user cluster-admin -z in-memory-channel-controller -n $EVENTING_NAMESPACE
  oc adm policy add-cluster-role-to-user cluster-admin -z default -n knative-sources

  echo ">>> Setting SSL_CERT_FILE for Knative Eventing Controller"
  oc set env -n $EVENTING_NAMESPACE deployment/eventing-controller SSL_CERT_FILE=/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt

  wait_until_pods_running $EVENTING_NAMESPACE || return 1
}

function install_in_memory_channel_provisioner(){
  header "Standing up In-Memory ClusterChannelProvisioner"
  resolve_resources config/provisioners/in-memory-channel/ channel-resolved.yaml $TARGET_IMAGE_PREFIX

  tag_core_images channel-resolved.yaml

  oc apply -f channel-resolved.yaml
}

function install_knative_eventing_sources(){
  header "Installing Knative Eventing Sources"
  oc apply -f ${EVENTING_SOURCES_RELEASE}
  wait_until_pods_running knative-sources || return 1
}

function create_test_resources() {
  echo ">> Ensuring pods in test namespaces can access test images"
  oc policy add-role-to-group system:image-puller system:serviceaccounts --namespace=$EVENTING_NAMESPACE

  echo ">> Creating imagestream tags for all test images"
  tag_test_images test/test_images

  # read to array
  testNamesArray=($(cat TEST_NAMES |tr "\n" " "))

  # process array to create the NS and give SCC
  for i in "${testNamesArray[@]}"
  do
    oc adm policy add-scc-to-user anyuid -z default -n $i
    oc adm policy add-scc-to-user privileged -z default -n $i
    oc adm policy add-scc-to-user anyuid -z eventing-broker-filter -n $i
    oc adm policy add-scc-to-user privileged -z eventing-broker-filter -n $i
    oc adm policy add-cluster-role-to-user cluster-admin -z eventing-broker-filter -n $i
  done

}

function tag_core_images(){
  local resolved_file_name=$1

  oc policy add-role-to-group system:image-puller system:serviceaccounts:${EVENTING_NAMESPACE} --namespace=${OPENSHIFT_BUILD_NAMESPACE}

  echo ">> Creating imagestream tags for images referenced in yaml files"
  IMAGE_NAMES=$(cat $resolved_file_name | grep -i "image:\|value:" | grep "$INTERNAL_REGISTRY" | awk '{print $2}' | awk -F '/' '{print $3}')
  for name in $IMAGE_NAMES; do
    tag_built_image ${name} ${name} latest
  done
}

function readTestFiles() {
  for test in "./test/e2e"/*_test.go; do
    grep "func Test" $test | awk '{print $2}' | awk -F'(' '{print $1}' >> TEST_NAMES;
  done

 sed -i "s/\([A-Z]\)/-\L\1/g" TEST_NAMES
 sed -i "s/^-//" TEST_NAMES
}

function create_test_namespace(){
  # read to array
  testNamesArray=($(cat TEST_NAMES |tr "\n" " "))

  # process array to create the NS and give SCC
  for i in "${testNamesArray[@]}"
  do
    oc new-project $i
    oc adm policy add-scc-to-user anyuid -z default -n $i
    oc adm policy add-scc-to-user privileged -z default -n $i
  done
}

function enable_knative_interaction_with_registry() {
  local configmap_name=config-service-ca
  local cert_name=service-ca.crt
  local mount_path=/var/run/secrets/kubernetes.io/servicecerts

  oc -n $SERVING_NAMESPACE create configmap $configmap_name
  oc -n $SERVING_NAMESPACE annotate configmap $configmap_name service.alpha.openshift.io/inject-cabundle="true"
  wait_until_configmap_contains $SERVING_NAMESPACE $configmap_name $cert_name
  oc -n $SERVING_NAMESPACE set volume deployment/controller --add --name=service-ca --configmap-name=$configmap_name --mount-path=$mount_path
  oc -n $SERVING_NAMESPACE set env deployment/controller SSL_CERT_FILE=$mount_path/$cert_name
}

function run_e2e_tests(){
  header "Running tests"
  options=""
  (( EMIT_METRICS )) && options="-emitmetrics"
  report_go_test \
    -v -tags=e2e -count=1 -timeout=20m -short -parallel=1 \
    ./test/e2e \
    --kubeconfig $KUBECONFIG \
    --dockerrepo ${INTERNAL_REGISTRY}/${EVENTING_NAMESPACE} \
    ${options} || return 1
}

function delete_istio_openshift(){
  echo ">> Bringing down Istio"
  oc delete ControlPlane/basic-install -n istio-system
}

function delete_serving_openshift() {
  echo ">> Bringing down Serving"
  oc delete --ignore-not-found=true -f $SERVING_RELEASE
}

function delete_build_openshift() {
  echo ">> Bringing down Build"
  oc delete --ignore-not-found=true -f $BUILD_RELEASE
}

function delete_knative_eventing_sources(){
  header "Brinding down Knative Eventing Sources"
  oc delete --ignore-not-found=true -f $EVENTING_SOURCES_RELEASE
}

function delete_knative_eventing(){
  header "Bringing down Eventing"
  oc delete --ignore-not-found=true -f eventing-resolved.yaml
}

function delete_in_memory_channel_provisioner(){
  header "Bringing down In-Memory ClusterChannelProvisioner"
  oc delete --ignore-not-found=true -f channel-resolved.yaml
}

function teardown() {
  rm TEST_NAMES
  delete_in_memory_channel_provisioner
  delete_knative_eventing_sources
  delete_knative_eventing
  delete_serving_openshift
  delete_build_openshift
  delete_istio_openshift
}

function tag_test_images() {
  local dir=$1
  image_dirs="$(find ${dir} -mindepth 1 -maxdepth 1 -type d)"

  for image_dir in ${image_dirs}; do
    name=$(basename ${image_dir})
    tag_built_image knative-eventing-test-${name} ${name} latest

  done
}

function tag_built_image() {
  local remote_name=$1
  local local_name=$2
  local build_tag=$3
  oc tag --insecure=${INSECURE} -n ${EVENTING_NAMESPACE} ${OPENSHIFT_REGISTRY}/${OPENSHIFT_BUILD_NAMESPACE}/stable:${remote_name} ${local_name}:${build_tag}
}

function run_origin_e2e() {
  local param_file=e2e-origin-params.txt
  (
    echo "NAMESPACE=$EVENTING_NAMESPACE"
    echo "IMAGE_TESTS=registry.svc.ci.openshift.org/openshift/origin-v4.0:tests"
    echo "TEST_COMMAND=TEST_SUITE=openshift/conformance/parallel run-tests"
  ) > $param_file
  
  oc -n $EVENTING_NAMESPACE create configmap kubeconfig --from-file=kubeconfig=$KUBECONFIG
  oc -n $EVENTING_NAMESPACE new-app -f ./openshift/origin-e2e-job.yaml --param-file=$param_file
  
  timeout 240 "oc get pods -n $EVENTING_NAMESPACE | grep e2e-origin-testsuite | grep -E 'Running'"
  e2e_origin_pod=$(oc get pods -n $EVENTING_NAMESPACE | grep e2e-origin-testsuite | grep -E 'Running' | awk '{print $1}')
  timeout 3600 "oc -n $EVENTING_NAMESPACE exec $e2e_origin_pod -c e2e-test-origin ls /tmp/artifacts/e2e-origin/test_logs.tar"
  oc cp ${EVENTING_NAMESPACE}/${e2e_origin_pod}:/tmp/artifacts/e2e-origin/test_logs.tar .
  tar xvf test_logs.tar -C /tmp/artifacts
  mkdir -p /tmp/artifacts/junit
  mv $(find /tmp/artifacts -name "junit_e2e_*.xml") /tmp/artifacts/junit
  mv /tmp/artifacts/tmp/artifacts/e2e-origin/e2e-origin.log /tmp/artifacts
}

function scale_up_workers(){
  local cluster_api_ns="openshift-machine-api"

  oc get machineset -n ${cluster_api_ns} --show-labels

  # Get the name of the first machineset that has at least 1 replica
  local machineset=$(oc get machineset -n ${cluster_api_ns} -o custom-columns="name:{.metadata.name},replicas:{.spec.replicas}" | grep " 1" | head -n 1 | awk '{print $1}')
  # Bump the number of replicas to 6 (+ 1 + 1 == 8 workers)
  oc patch machineset -n ${cluster_api_ns} ${machineset} -p '{"spec":{"replicas":6}}' --type=merge
  wait_until_machineset_scales_up ${cluster_api_ns} ${machineset} 6
}

# Waits until the machineset in the given namespaces scales up to the
# desired number of replicas
# Parameters: $1 - namespace
#             $2 - machineset name
#             $3 - desired number of replicas
function wait_until_machineset_scales_up() {
  echo -n "Waiting until machineset $2 in namespace $1 scales up to $3 replicas"
  for i in {1..150}; do  # timeout after 15 minutes
    local available=$(oc get machineset -n $1 $2 -o jsonpath="{.status.availableReplicas}")
    if [[ ${available} -eq $3 ]]; then
      echo -e "\nMachineSet $2 in namespace $1 successfully scaled up to $3 replicas"
      return 0
    fi
    echo -n "."
    sleep 6
  done
  echo - "\n\nError: timeout waiting for machineset $2 in namespace $1 to scale up to $3 replicas"
  return 1
}

scale_up_workers || exit 1

readTestFiles || exit 1

create_test_namespace || exit 1

failed=0

(( !failed )) && install_istio || failed=1

(( !failed )) && install_knative_build || failed=1

(( !failed )) && install_knative_serving || failed=1

(( !failed )) && install_knative_eventing || failed=1

(( !failed )) && install_in_memory_channel_provisioner || failed=1

(( !failed )) && install_knative_eventing_sources || failed=1

(( !failed )) && create_test_resources

if [[ $TEST_ORIGIN_CONFORMANCE == true ]]; then
  (( !failed )) && run_origin_e2e || failed=1
fi

(( !failed )) && run_e2e_tests || failed=1

(( !failed )) && run_demo || failed=1

(( failed )) && dump_cluster_state

teardown

(( failed )) && exit 1

success
