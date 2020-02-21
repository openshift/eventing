#!/bin/sh 

source $(dirname $0)/../vendor/knative.dev/test-infra/scripts/e2e-tests.sh
source $(dirname $0)/release/resolve.sh

set -x

readonly K8S_CLUSTER_OVERRIDE=$(oc config current-context | awk -F'/' '{print $2}')
readonly API_SERVER=$(oc config view --minify | grep server | awk -F'//' '{print $2}' | awk -F':' '{print $1}')
readonly INTERNAL_REGISTRY="${INTERNAL_REGISTRY:-"image-registry.openshift-image-registry.svc:5000"}"
readonly USER=$KUBE_SSH_USER #satisfy e2e_flags.go#initializeFlags()
readonly OPENSHIFT_REGISTRY="${OPENSHIFT_REGISTRY:-"registry.svc.ci.openshift.org"}"
readonly INSECURE="${INSECURE:-"false"}"
readonly TEST_ORIGIN_CONFORMANCE="${TEST_ORIGIN_CONFORMANCE:-"false"}"
readonly SERVING_NAMESPACE=knative-serving
readonly EVENTING_NAMESPACE=knative-eventing
readonly SERVICEMESH_NAMESPACE=knative-serving-ingress
export GATEWAY_NAMESPACE_OVERRIDE="$SERVICEMESH_NAMESPACE"
readonly TARGET_IMAGE_PREFIX="$INTERNAL_REGISTRY/$EVENTING_NAMESPACE/knative-eventing-"
readonly OLM_NAMESPACE="openshift-marketplace"

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

function install_strimzi(){
  strimzi_version=`curl https://github.com/strimzi/strimzi-kafka-operator/releases/latest |  awk -F 'tag/' '{print $2}' | awk -F '"' '{print $1}' 2>/dev/null`
  header_text "Strimzi install"
  kubectl create namespace kafka
  curl -L "https://github.com/strimzi/strimzi-kafka-operator/releases/download/${strimzi_version}/strimzi-cluster-operator-${strimzi_version}.yaml" \
  | sed 's/namespace: .*/namespace: kafka/' \
  | kubectl -n kafka apply -f -

  header_text "Applying Strimzi Cluster file"
  kubectl -n kafka apply -f "https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/${strimzi_version}/examples/kafka/kafka-persistent-single.yaml"

  header_text "Waiting for Strimzi to become ready"
  sleep 5; while echo && kubectl get pods -n kafka | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done
}

function install_knative_serving(){
  header "Installing Knative Serving"

  oc new-project $SERVING_NAMESPACE

  # Install CatalogSource in OLM namespace
  oc apply -n $OLM_NAMESPACE -f openshift/olm/knative-serving.catalogsource.yaml
  timeout_non_zero 900 '[[ $(oc get pods -n $OLM_NAMESPACE | grep -c serverless) -eq 0 ]]' || return 1
  wait_until_pods_running $OLM_NAMESPACE

  # Deploy Serverless Operator
  deploy_serverless_operator

  # Wait for the CRD to appear
  timeout_non_zero 900 '[[ $(oc get crd | grep -c knativeservings) -eq 0 ]]' || return 1

  # Install Knative Serving
  cat <<-EOF | oc apply -f -
apiVersion: operator.knative.dev/v1alpha1
kind: KnativeServing
metadata:
  name: knative-serving
  namespace: ${SERVING_NAMESPACE}
EOF

  # Wait for 4 pods to appear first
  timeout_non_zero 900 '[[ $(oc get pods -n $SERVING_NAMESPACE --no-headers | wc -l) -lt 4 ]]' || return 1
  wait_until_pods_running $SERVING_NAMESPACE || return 1

  wait_until_service_has_external_ip $SERVICEMESH_NAMESPACE istio-ingressgateway || fail_test "Ingress has no external IP"
  wait_until_hostname_resolves "$(kubectl get svc -n $SERVICEMESH_NAMESPACE istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

  header "Knative Serving Installed successfully"
}

function deploy_serverless_operator(){
  local name="serverless-operator"
  local operator_ns
  operator_ns=$(kubectl get og --all-namespaces | grep global-operators | awk '{print $1}')

  cat <<-EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${name}-subscription
  namespace: ${operator_ns}
spec:
  source: ${name}
  sourceNamespace: $OLM_NAMESPACE
  name: ${name}
  channel: techpreview
EOF
}

function create_knative_namespace(){
  local COMPONENT="knative-$1"

  cat <<-EOF | oc apply -f -
	apiVersion: v1
	kind: Namespace
	metadata:
	  name: ${COMPONENT}
	EOF
}

function deploy_knative_operator(){
  local COMPONENT="knative-$1"
  local API_GROUP=$1
  local KIND=$2

  cat <<-EOF | oc apply -f -
	apiVersion: v1
	kind: Namespace
	metadata:
	  name: ${COMPONENT}
	EOF
  if oc get crd operatorgroups.operators.coreos.com >/dev/null 2>&1; then
    cat <<-EOF | oc apply -f -
	apiVersion: operators.coreos.com/v1
	kind: OperatorGroup
	metadata:
	  name: ${COMPONENT}
	  namespace: ${COMPONENT}
	EOF
  fi
  cat <<-EOF | oc apply -f -
	apiVersion: operators.coreos.com/v1alpha1
	kind: Subscription
	metadata:
	  name: ${COMPONENT}-subscription
	  generateName: ${COMPONENT}-
	  namespace: ${COMPONENT}
	spec:
	  source: ${COMPONENT}-operator
	  sourceNamespace: $OLM_NAMESPACE
	  name: ${COMPONENT}-operator
	  channel: alpha
	EOF

  # # Wait until the server knows about the Install CRD before creating
  # # an instance of it below
  timeout_non_zero 60 '[[ $(oc get crd knative${API_GROUP}s.${API_GROUP}.knative.dev -o jsonpath="{.status.acceptedNames.kind}" | grep -c $KIND) -eq 0 ]]' || return 1
}

function install_knative_eventing(){
  header "Installing Knative Eventing"

  create_knative_namespace eventing

  echo ">> Patching Knative Eventing CatalogSource to reference CI produced images"
  CURRENT_GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  RELEASE_YAML="https://raw.githubusercontent.com/openshift/knative-eventing/${CURRENT_GIT_BRANCH}/openshift/release/knative-eventing-ci.yaml,https://raw.githubusercontent.com/openshift-knative/knative-eventing-operator/master/deploy/resources/networkpolicies.yaml"
  sed "s|--filename=.*|--filename=${RELEASE_YAML}|"  openshift/olm/knative-eventing.catalogsource.yaml > knative-eventing.catalogsource-ci.yaml

  oc apply -n $OLM_NAMESPACE -f knative-eventing.catalogsource-ci.yaml
  # oc apply -n $OLM_NAMESPACE -f openshift/olm/knative-eventing.catalogsource.yaml
  timeout_non_zero 900 '[[ $(oc get pods -n $OLM_NAMESPACE | grep -c knative-eventing) -eq 0 ]]' || return 1
  wait_until_pods_running $OLM_NAMESPACE

  oc get pod -n $OLM_NAMESPACE -o yaml
 
  # Deploy Knative Operators Eventing
  deploy_knative_operator eventing KnativeEventing

  # Create imagestream for images generated in CI namespace
  tag_core_images openshift/release/knative-eventing-ci.yaml

  # Wait for 5 pods to appear first
  timeout_non_zero 900 '[[ $(oc get pods -n $EVENTING_NAMESPACE --no-headers | wc -l) -lt 5 ]]' || return 1
  wait_until_pods_running $EVENTING_NAMESPACE || return 1

  # Assert that there are no images used that are not CI images (which should all be using the $INTERNAL_REGISTRY)
  # (except for the knative-eventing-operator)
  #oc get pod -n knative-eventing -o yaml | grep image: | grep -v knative-eventing-operator | grep -v ${INTERNAL_REGISTRY} && return 1 || true
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
    oc create serviceaccount eventing-broker-ingress -n $i
    oc create serviceaccount eventing-broker-filter -n $i
    oc adm policy add-scc-to-user anyuid -z default -n $i
    oc adm policy add-scc-to-user privileged -z default -n $i
    oc adm policy add-scc-to-user anyuid -z eventing-broker-filter -n $i
    oc adm policy add-scc-to-user privileged -z eventing-broker-filter -n $i
    oc adm policy add-cluster-role-to-user cluster-admin -z eventing-broker-filter -n $i
    oc adm policy add-scc-to-user anyuid -z eventing-broker-ingress -n $i
    oc adm policy add-scc-to-user privileged -z eventing-broker-ingress -n $i
    oc adm policy add-cluster-role-to-user cluster-admin -z eventing-broker-ingress -n $i
  done

}

function tag_core_images(){
  local resolved_file_name=$1

  oc policy add-role-to-group system:image-puller system:serviceaccounts:${EVENTING_NAMESPACE} --namespace=${OPENSHIFT_BUILD_NAMESPACE}

  echo ">> Creating imagestream tags for images referenced in yaml files"
  IMAGE_NAMES=$(cat $resolved_file_name | grep -i "image:\|value:" | grep "$INTERNAL_REGISTRY" | awk '{print $2}' | awk -F '/' '{print $3}')
  for nametag in $IMAGE_NAMES; do
    name=$(echo $nametag | cut -d: -f1)
    tag_built_image ${name} ${name}
  done
}

function readTestFiles() {
  for test in "./test/e2e"/*_test.go; do
    grep "func Test" $test | awk '{print $2}' | awk -F'(' '{print $1}' >> TEST_NAMES;
  done

 sed -i "s/\([A-Z]\)/-\L\1/g" TEST_NAMES
 sed -i "s/^-//" TEST_NAMES

 # add new test name structure to the list:
 echo "test-default-broker-with-many-deprecated-triggers" >> TEST_NAMES;
 echo "test-default-broker-with-many-attribute-triggers" >> TEST_NAMES;
 echo "test-default-broker-with-many-attribute-and-extension-triggers" >> TEST_NAMES;

 echo "test-channel-namespace-defaulter-in-memory-channel" >> TEST_NAMES;
 echo "test-channel-cluster-defaulter-in-memory-channel" >> TEST_NAMES;
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

function run_e2e_tests(){
  header "Running tests"
  report_go_test \
    -v -tags=e2e -count=1 -timeout=70m -parallel=1 \
    ./test/e2e \
    --kubeconfig "$KUBECONFIG" \
    --dockerrepo "${INTERNAL_REGISTRY}/${EVENTING_NAMESPACE}" \
    ${options} || failed=1
}

function delete_strimzi(){

  strimzi_version=`curl https://github.com/strimzi/strimzi-kafka-operator/releases/latest |  awk -F 'tag/' '{print $2}' | awk -F '"' '{print $1}' 2>/dev/null`

  header_text "Delete Strimzi Cluster"
  kubectl -n kafka delete -f "https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/${strimzi_version}/examples/kafka/kafka-persistent-single.yaml"

  header_text "remove Strimzi"
  kubectl -n kafka delete -f "https://github.com/strimzi/strimzi-kafka-operator/releases/download/${strimzi_version}/strimzi-cluster-operator-${strimzi_version}.yaml"
  kubectl delete namespace kafka
}

function delete_istio_openshift(){
  echo ">> Bringing down Istio"
  oc delete ControlPlane/minimal-istio -n istio-system
}

function delete_serving_openshift() {
  echo ">> Bringing down Serving"
  oc delete --ignore-not-found=true -f $SERVING_RELEASE
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
  delete_knative_eventing
  delete_serving_openshift
  delete_istio_openshift
  delete_strimzi
}

function tag_test_images() {
  local dir=$1
  image_dirs="$(find ${dir} -mindepth 1 -maxdepth 1 -type d)"

  for image_dir in ${image_dirs}; do
    name=$(basename ${image_dir})
    tag_built_image knative-eventing-test-${name} ${name}

  done
}

function tag_built_image() {
  local remote_name=$1
  local local_name=$2
  oc tag --insecure=${INSECURE} -n ${EVENTING_NAMESPACE} ${OPENSHIFT_REGISTRY}/${OPENSHIFT_BUILD_NAMESPACE}/stable:${remote_name} ${local_name}:latest
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

function dump_openshift_olm_state(){
  echo ">>> subscriptions.operators.coreos.com:"
  oc get subscriptions.operators.coreos.com -o yaml --all-namespaces   # This is for status checking.

  echo ">>> catalog operator log:"
  oc logs -n openshift-operator-lifecycle-manager deployment/catalog-operator
}

scale_up_workers || exit 1

readTestFiles || exit 1

create_test_namespace || exit 1

failed=0

(( !failed )) && install_strimzi || failed=1

(( !failed )) && install_knative_serving || failed=1

(( !failed )) && install_knative_eventing || failed=1

(( !failed )) && create_test_resources || failed=1

if [[ $TEST_ORIGIN_CONFORMANCE == true ]]; then
  (( !failed )) && run_origin_e2e || failed=1
fi

(( !failed )) && run_e2e_tests || failed=1

(( failed )) && dump_cluster_state

(( failed )) && dump_openshift_olm_state

teardown

(( failed )) && exit 1

success
