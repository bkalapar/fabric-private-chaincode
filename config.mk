# Copyright IBM Corp. All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0

GOFLAGS :=
GO := go $(GOFLAGS)

DOCKERFLAGS :=
DOCKER := docker $(DOCKERFLAGS)

PROJECT_NAME=fabric-private-chaincode

export SGX_MODE ?= HW
export SGX_BUILD ?= PRERELEASE

export FABRIC_PATH ?= ${GOPATH}/src/github.com/hyperledger/fabric

# Give the option to overload by custom protoc
# e.g. this is overloaded by travis and docker dev as we use protoc 3.11.4 to build
# protos in tlcc_enclave but use protoc 3.0.x to build SGX SDK and SSL
export PROTOC_CMD ?= protoc

JAVA ?= java
PLANTUML_JAR ?= plantuml.jar
PLANTUML_CMD ?= $(JAVA) -jar $(PLANTUML_JAR)
PLANTUML_IMG_FORMAT ?= png # pdf / png / svg
