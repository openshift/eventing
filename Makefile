#This makefile is used by ci-operator

CGO_ENABLED=0
GOOS=linux
CORE_IMAGES=$(shell find ./cmd -name main.go ! -path "./cmd/broker/*" ! -path "./cmd/mtbroker/*" | sed 's/main.go//')
TEST_IMAGES=$(shell find ./test/test_images -mindepth 1 -maxdepth 1 -type d)
KO_DOCKER_REPO=${DOCKER_REPO_OVERRIDE}
BRANCH=
TEST=
IMAGE=

# Guess location of openshift/release repo. NOTE: override this if it is not correct.
OPENSHIFT=${CURDIR}/../../github.com/openshift/release

install:
	go install $(CORE_IMAGES)
	go build -o $(GOPATH)/bin/broker_ingress ./cmd/broker/ingress/
	go build -o $(GOPATH)/bin/broker_filter ./cmd/broker/filter/
	go build -o $(GOPATH)/bin/mtbroker_ingress ./cmd/mtbroker/ingress/
	go build -o $(GOPATH)/bin/mtbroker_filter ./cmd/mtbroker/filter/
.PHONY: install

test-install:
	go install $(TEST_IMAGES)
.PHONY: test-install

test-e2e:
	sh openshift/e2e-tests-openshift.sh
.PHONY: test-e2e

# Requires ko 0.2.0 or newer.
test-images:
	for img in $(TEST_IMAGES); do \
		ko resolve --tags=latest -RBf $$img ; \
	done
.PHONY: test-images

test-image-single:
	ko resolve --tags=latest -RBf test/test_images/$(IMAGE)
.PHONY: test-image-single

# Run make DOCKER_REPO_OVERRIDE=<your_repo> test-e2e-local if test images are available
# in the given repository. Make sure you first build and push them there by running `make test-images`.
# Run make BRANCH=<ci_promotion_name> test-e2e-local if test images from the latest CI
# build for this branch should be used. Example: `make BRANCH=knative-v0.14.2 test-e2e-local`.
# If neither DOCKER_REPO_OVERRIDE nor BRANCH are defined the tests will use test images
# from the last nightly build.
# If TEST is defined then only the single test will be run.
test-e2e-local:
	./openshift/e2e-tests-local.sh $(TEST)
.PHONY: test-e2e-local

# Generate Dockerfiles used by ci-operator. The files need to be committed manually.
generate-dockerfiles:
	rm -rf openshift/ci-operator/knative-images/*
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-images $(CORE_IMAGES)
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-images broker_ingress
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-images broker_filter
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-images mtbroker_ingress
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-images mtbroker_filter
	rm -rf openshift/ci-operator/knative-test-images/*
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-test-images $(TEST_IMAGES)
.PHONY: generate-dockerfiles

# Generate an aggregated knative yaml file with replaced image references
generate-release:
	./openshift/release/generate-release.sh $(RELEASE)
	./openshift/release/generate-release.sh $(RELEASE) ci
.PHONY: generate-release

# Update CI configuration in the $(OPENSHIFT) directory.
# NOTE: Makes changes outside this repository.
update-ci:
	sh ./openshift/ci-operator/update-ci.sh $(OPENSHIFT) $(CORE_IMAGES)
.PHONY: update-ci
