#!/bin/bash

readonly DEMO_URL="https://raw.githubusercontent.com/matzew/demos/serving_updates_ocp4/knative-kubecon"

function run_demo(){
  header "Running Knative Build/Serving/Eventing Demo"
  
  oc import-image -n openshift golang --from=centos/go-toolset-7-centos7 --confirm
  oc import-image -n openshift golang:1.11 --from=centos/go-toolset-7-centos7 --confirm
  
  oc new-project myproject

  oc adm policy add-cluster-role-to-user cluster-admin -z default -n myproject
  oc adm policy add-scc-to-user anyuid -z default -n myproject
  oc adm policy add-scc-to-user privileged -z default -n myproject

  apply build/000-rolebinding.yaml
  
  apply build/010-build-template.yaml
  apply serving/010-service.yaml

  wait_for_all_pods myproject || return 1

  local ip=$(oc get svc istio-ingressgateway -n istio-system -o 'jsonpath={.status.loadBalancer.ingress[0].hostname}')
  
  wait_for_redhat $ip || return 1

  apply serving/011-service-update.yaml

  wait_for_all_pods myproject || return 1

  wait_for_redhat $ip || return 1

  apply serving/012-service-traffic.yaml

  wait_for_all_pods myproject || return 1

  wait_for_redhat $ip || return 1

  apply serving/013-service-final.yaml

  wait_for_dumpy_00001_to_shutdown || return 1

  wait_for_redhat $ip || return 1

  check_no_dumpy_00001 || return 1

  apply eventing/010-trigger.yaml
  apply eventing/021-source.yaml

  wait_for_all_pods myproject || return 1

  # Check that events arrive at the application
  wait_for_logged_events
}

function apply(){
  local yaml_path=$1
  curl -L ${DEMO_URL}/${yaml_path} |\
  sed "/container\:/ a \
\            resources:\n\              requests:\n\                cpu: 50m" |\
  oc apply -f -
}

function delete(){
  local yaml_path=$1
  curl -L ${DEMO_URL}/${yaml_path} | oc delete -f -
}

function delete_demo(){
  delete build/000-rolebinding.yaml
  oc delete project myproject
}

function wait_for_all_pods {
  timeout 600 "! oc get pods -n $1 2>&1 | grep -v -E '(Running|Completed|STATUS)'"
}

function wait_for_logged_events(){
  POD=$(oc get pods | grep dumpy-00002-deployment | awk '{ print $1 }' | awk '{ print $1 }')
  timeout 300 "oc logs $POD -c user-container | grep 'Ce-Source:'"
}

function wait_for_redhat(){
  # Check that the app can server requests
  timeout 60 "echo \$(curl -v -H 'Host: dumpy.myproject.example.com' http://${1}/health) | grep 888"
}

function wait_for_dumpy_00001_to_shutdown(){
  timeout 600 "! oc get pods | grep dumpy-00001-deployment"
}

function check_no_dumpy_00001(){
  ! oc get pods | grep dumpy-00001-deployment
}

function timeout() {
  SECONDS=0; TIMEOUT=$1; shift
  until eval $*; do
    sleep 5
    [[ $SECONDS -gt $TIMEOUT ]] && echo "ERROR: Timed out" && return 1
  done
  return 0
}
