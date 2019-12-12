#This makefile is used by ci-operator

CGO_ENABLED=0
GOOS=linux
CORE_IMAGES=$(shell find ./cmd -name main.go | sed 's/main.go//')
TEST_IMAGES=$(shell find ./test/test_images -mindepth 1 -maxdepth 1 -type d)
LOCAL_IMAGES=imc-controller imc-dispatcher

# Guess location of openshift/release repo. NOTE: override this if it is not correct.
OPENSHIFT=${CURDIR}/../../github.com/openshift/release

install:
	go install $(CORE_IMAGES)
	go build -o $(GOPATH)/bin/imc-controller ./cmd/in_memory/channel_controller
	go build -o $(GOPATH)/bin/imc-dispatcher ./cmd/in_memory/channel_dispatcher
.PHONY: install

test-install:
	go install $(TEST_IMAGES)
.PHONY: test-install

test-e2e:
	sh openshift/e2e-tests-openshift.sh
.PHONY: test-e2e

test-origin-conformance:
	sh TEST_ORIGIN_CONFORMANCE=true openshift/e2e-tests-openshift.sh
.PHONY: test-origin-conformance

# Generate Dockerfiles used by ci-operator. The files need to be committed manually.
generate-dockerfiles:
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-images $(CORE_IMAGES) $(LOCAL_IMAGES)
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-test-images $(TEST_IMAGES)
.PHONY: generate-dockerfiles

# Generate an aggregated knative yaml file with replaced image references
generate-release:
	./openshift/release/generate-release.sh $(RELEASE)
.PHONY: generate-release

# Update CI configuration in the $(OPENSHIFT) directory.
# NOTE: Makes changes outside this repository.
update-ci:
	sh ./openshift/ci-operator/update-ci.sh $(OPENSHIFT) $(CORE_IMAGES) $(LOCAL_IMAGES)
.PHONY: update-ci
