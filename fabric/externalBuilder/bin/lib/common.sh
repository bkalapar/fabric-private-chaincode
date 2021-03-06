# Copyright 2020 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0

# assumes SCRIPTDIR is defined ...

FPC_TOP_DIR=$(readlink -f "${SCRIPTDIR}/../../../")
FABRIC_SCRIPTDIR="${FPC_TOP_DIR}/fabric/bin/"
. ${FABRIC_SCRIPTDIR}/lib/common_utils.sh

FPC_CC_TYPE="fpc-c"

: ${FPC_HOSTING_MODE:=host} # alternatives: host, docker (not yet implemented), kubernetes (not yet implemented)


METADATA_FILE="metadata.json"
ENCLAVE_FILE="enclave.signed.so"
MRENCLAVE_FILE="mrenclave"


# assumes CC_SOURCE_DIR & CC_METADATA_DIR: / provides: REQUEST_CC_TYPE
check_pkg_meta(){
    [ -f "${CC_METADATA_DIR}/${METADATA_FILE}" ] || die "no metadata file '${METADATA_FILE}'"
    REQUEST_CC_TYPE="$(jq -r .type "${CC_METADATA_DIR}/metadata.json" | tr '[:upper:]' '[:lower:]')"
}

# assumes CC_SOURCE_DIR & CC_METADATA_DIR: / provides:SGX_MODE
check_pkg_src(){
    SGX_MODE="$(jq -r .sgx_mode "${CC_METADATA_DIR}/metadata.json")"
    [ ! -z "${SGX_MODE}" ]                       || die "SGX mode not specified in metadata file"

    [ -f "${CC_SOURCE_DIR}/${MRENCLAVE_FILE}" ]  || die "no enclave file '${ENCLAVE_FILE}'"
    [ -f "${CC_SOURCE_DIR}/${ENCLAVE_FILE}" ]    || die "no MRENCLAVE file '${MRENCLAVE_FILE}'"
}


# run directly on host
cc_build_for_host() {

    # - just make sure we have in build-dir the chaincode binary, required libraries as well
    #   as ${ENCLAVE_FILE} and ${MRENCLAVE_FILE} in the appropriate place that we can run
    #   directly out of that directory

    CC_PATH="${CC_BUILD_DIR}"
    CC_LIB_PATH="${CC_PATH}/enclave/lib"

    mkdir -p ${CC_LIB_PATH}

    # - ecc shims
    try ln -s "${FPC_TOP_DIR}/ecc/ecc" "${CC_PATH}/chaincode"
    try ln -s "${FPC_TOP_DIR}/ecc_enclave/_build/lib/libsgxcc.so" "${CC_LIB_PATH}/"

    # - chaincode specific stuff
    try cp "${CC_SOURCE_DIR}/${MRENCLAVE_FILE}" "${CC_PATH}"
    try cp "${CC_SOURCE_DIR}/${ENCLAVE_FILE}" "${CC_LIB_PATH}"

    # - store also meta-data file
    try cp "${CC_METADATA_DIR}/${METADATA_FILE}" "${CC_PATH}"
}

cc_build_for_docker() {
    # TODO: Implement me
    die "building FPC for docker is not yet implemented"

    # Adapt old container switcheroo ...
    # - DOCKER_IMAGE_NAME="some string" & remember it in CC_BUILD_DIR
    # - try make SGX_MODE=${SGX_MODE} ENCLAVE_SO_PATH=${CC_ENCLAVESOPATH} DOCKER_IMAGE=${DOCKER_IMAGE_NAME} -C ${FPC_TOP_DIR}/ecc docker-fpc-app
}

# assumes CC_BUILD_DIR & CC_RT_METADATA_DIR
# provides: SGX_MODE, PEER_ADDRESS, TLS_ARTIFACTS_DIR & all env-vars expected by shim
process_runtime_metadata() {
    # Note: while the sample scripts re-use ${CC_RT_METADATA_DIR} to extract the
    # artifacts from chaincode.json, the docu explicitly says one should treat
    # that dir as read-only. So we create a separate tmp directory to store
    # extracted artifacts.

    TLS_ARTIFACTS_DIR="/tmp/fpc-extbuilder.$$"
    try mkdir -p "${TLS_ARTIFACTS_DIR}"


    [ -f "${CC_BUILD_DIR}/${METADATA_FILE}" ] || die "no metadata file '${METADATA_FILE}'"
    SGX_MODE="$(jq -r .sgx_mode "${CC_BUILD_DIR}/metadata.json")"
    [ ! -z "${SGX_MODE}" ]                       || die "SGX mode not specified in metadata file"

    [ -f "${CC_RT_METADATA_DIR}/chaincode.json" ] || die "chaincode.jsaon does not exist"
    export CORE_CHAINCODE_ID_NAME="$(jq -r .chaincode_id "${CC_RT_METADATA_DIR}/chaincode.json")" || die "could not extract chaincode-id"
    PEER_ADDRESS=$(jq -r .peer_address "${CC_RT_METADATA_DIR}/chaincode.json") || die "could not extract peer address"

    export CORE_PEER_LOCALMSPID="$(jq -r .mspid "${CC_RT_METADATA_DIR}/chaincode.json")" || die "could not extract peer MSPID"

    if [ -z "$(jq -r .client_cert "${CC_RT_METADATA_DIR}/chaincode.json")" ]; then
	export CORE_PEER_TLS_ENABLED="false"
    else
	export CORE_PEER_TLS_ENABLED="true"
	export CORE_TLS_CLIENT_CERT_FILE="${TLS_ARTIFACTS_DIR}/client.crt"
	try jq -r .client_cert "${CC_RT_METADATA_DIR}/chaincode.json" > "${CORE_TLS_CLIENT_CERT_FILE}"
	export CORE_TLS_CLIENT_KEY_FILE="${TLS_ARTIFACTS_DIR}/client.key"
	try jq -r .client_key  "${CC_RT_METADATA_DIR}/chaincode.json" > "${CORE_TLS_CLIENT_KEY_FILE}"
	export CORE_PEER_TLS_ROOTCERT_FILE="${TLS_ARTIFACTS_DIR}/root.crt"
	try jq -r .root_cert   "${CC_RT_METADATA_DIR}/chaincode.json" > "${CORE_PEER_TLS_ROOTCERT_FILE}"
    fi

    # For debugging purposes, we also symlink the source metadata & build artifacts
    try ln -s "${CC_BUILD_DIR}/" "${TLS_ARTIFACTS_DIR}/build"
    try ln -s "${CC_RT_METADATA_DIR}/" "${TLS_ARTIFACTS_DIR}/rt-metadata"
}

# expects CC_BUILD_DIR and variables set in 'process_runtime_metadata'
# provides CC_PID, process id of chaincode
cc_run_on_host() {
    # get SGX SDK environment variables
    export SGX_SDK="/opt/intel/sgxsdk"
    if [ -z ${PKG_CONFIG_PATH+x} ]; then PKG_CONFIG_PATH=""; fi # Hack necessary as below otherwise uses undefined var
    . "${SGX_SDK}/environment"

    CC_LIB_PATH="${CC_BUILD_DIR}/enclave/lib"
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:${CC_LIB_PATH}"

    # Notes on starting chaincode
    # - cd is necessary so (relatively linked) enclave is found
    # - we start here in background as we also have to do setup but
    #   later have to block on the termination of the chaincode,
    #   hence remembering the CC_PID
    try cd "${CC_BUILD_DIR}"
    ./chaincode -peer.address="${PEER_ADDRESS}" 2>&1 | tee "${TLS_ARTIFACTS_DIR}/chaincode.log" &
    CC_PID=$!
    sleep 1
    kill -0 ${CC_PID} || die "Chaincode quit too quickly: (for log see '${TLS_ARTIFACTS_DIR}/chaincode.log')"
}

# expects CC_BUILD_DIR and variables set in 'process_runtime_metadata'
# provides CC_PID, process id of chaincode (container)
cc_run_on_docker() {
    # TODO: Implement me
    # - get docker image name from CC_BUILD_DIR
    # - start docker all CORE_.. env-variables explicitly passed and
    #   with any TLS artifacts mounted via a volume (using some path
    #   is externally, so we don't have to do path renaming ..)
    # - depending on sgx-mode, we also have to pass the SGX device & socket
    die "running FPC inside docker is not yet implemented"
}

# assumes CC_SOURCE_DIR & CC_METADATA_DIR are set
cc_build() {
    case "${FPC_HOSTING_MODE}" in
	host)
	    cc_build_for_host || die "failed to build for host"
	    ;;
	docker)
	    cc_build_for_docker || die "failed to build for docker"
	    ;;
	*)
	    die "unsupported hosting mode '${FPC_HOSTING_MODE}'"
    esac
}

# assumes CC_BUILD_DIR & CC_RT_METADATA_DIR are set
cc_run() {
    # - process inputs
    process_runtime_metadata || die "could not process runtime metadata"

    # - start the actual chaincode (in background)
    case "${FPC_HOSTING_MODE}" in
	host)
	    cc_run_on_host || die "failed to run on host"
	    ;;
	docker)
	    cc_run_on_docker || die "failed to run on docker"
	    ;;
	*)
	    die "unsupported hosting mode '${FPC_HOSTING_MODE}'"
    esac

    # Here we might eventually do additional setup functionality, e.g.,
    # managing sealed state. Note, though, that we do have information such as
    # channel id or alike so we can _not_ do normal peer cli chaincode
    # invocations to call "__setup" or alike! Hence we do that stil in peer.sh
    # for now ...

    # external builder interface asks us to return from script only once
    # chaincode process terminats
    wait ${CC_PID}
}

