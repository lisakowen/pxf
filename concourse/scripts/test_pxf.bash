#!/bin/bash

set -exo pipefail

CWDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${CWDIR}/pxf_common.bash"

export GPHOME=${GPHOME:-/usr/local/greenplum-db-devel}
export PXF_HOME=${GPHOME}/pxf
export JAVA_HOME=${JAVA_HOME}
export JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF8
export HADOOP_HEAPSIZE=512
export YARN_HEAPSIZE=512
export GPHD_ROOT=/singlecluster
if [[ ${HADOOP_CLIENT} == MAPR ]]; then
	export GPHD_ROOT=/opt/mapr
fi

function run_pxf_automation() {
	# Let's make sure that automation/singlecluster directories are writeable
	chmod a+w pxf_src/automation /singlecluster || true
	find pxf_src/automation/tinc* -type d -exec chmod a+w {} \;

	ln -s "${PWD}/pxf_src" ~gpadmin/pxf_src
	su gpadmin -c "
		source '${GPHOME}/greenplum_path.sh' &&
		psql -p 15432 -d template1 -c 'CREATE EXTENSION PXF'
	"

	cat > ~gpadmin/run_pxf_automation_test.sh <<-EOF
		set -exo pipefail

		source ${GPHOME}/greenplum_path.sh

		export PATH=\$PATH:${GPHD_ROOT}/bin
		export GPHD_ROOT=${GPHD_ROOT}
		export PXF_HOME=${PXF_HOME}
		export PGPORT=15432

		# JAVA_HOME is from pxf_common.bash
		export JAVA_HOME=${JAVA_HOME}

		make -C pxf_src/automation GROUP=${GROUP}
	EOF

	chown gpadmin:gpadmin ~gpadmin/run_pxf_automation_test.sh
	chmod a+x ~gpadmin/run_pxf_automation_test.sh
	su gpadmin -c ~gpadmin/run_pxf_automation_test.sh
}

function generate_extras_fat_jar() {
	mkdir -p /tmp/fatjar "${PXF_HOME}/tmp"
	pushd /tmp/fatjar
		find "${PXF_CONF_DIR}/lib" -name '*.jar' -exec jar -xf {} \;
		jar -cf "${PXF_HOME}/lib/pxf-extras-1.0.0.jar" .
		chown -R gpadmin:gpadmin "${PXF_HOME}/lib/pxf-extras-1.0.0.jar"
	popd
}

function configure_mapr_dependencies() {
	# Copy mapr specific jars to $PXF_CONF_DIR/lib
	HADOOP_COMMON=/opt/mapr/hadoop/hadoop-2.7.0/share/hadoop/common
	cp "${HADOOP_COMMON}/lib/maprfs-5.2.2-mapr.jar" \
		"${HADOOP_COMMON}/lib/hadoop-auth-2.7.0-mapr-1707.jar" \
		"${HADOOP_COMMON}/hadoop-common-2.7.0-mapr-1707.jar" "${PXF_CONF_DIR}/lib"
	# Copy *-site.xml files
	cp /opt/mapr/hadoop/hadoop-2.7.0/etc/hadoop/*-site.xml "${PXF_CONF_DIR}/servers/default"
	# Copy mapred-site.xml for recursive hdfs directories test
	# We need to do this step after PXF Server init
	cp "${PXF_CONF_DIR}/templates/mapred-site.xml" "${PXF_CONF_DIR}/servers/default/recursive-site.xml"
	# Set mapr port to 7222 in default.xml (sut)
	sed -i 's|<port>8020</port>|<port>7222</port>|' pxf_src/automation/src/test/resources/sut/default.xml
}

function setup_hadoop() {
	local hdfsrepo=$1

	[[ -z ${GROUP} ]] && return 0

	export SLAVES=1
	setup_impersonation "${hdfsrepo}"
	if grep 'hadoop-3' "${hdfsrepo}/versions.txt"; then
		adjust_for_hadoop3 "${hdfsrepo}"
	fi
	start_hadoop_services "${hdfsrepo}"
}

function _main() {
	# kill the sshd background process when this script exits. Otherwise, the
	# concourse build will run forever.
	trap 'pkill sshd' EXIT

	if [[ ${PROTOCOL} == s3 ]]; then
		echo Using S3 protocol
	elif [[ ${PROTOCOL} == minio ]]; then
		echo Using Minio with S3 protocol
		setup_minio
	elif [[ ${PROTOCOL} == gs ]]; then
		echo Using GS protocol
		cat <<-EOF > /tmp/gsc-ci-service-account.key.json
			${GOOGLE_CREDENTIALS}
		EOF
	elif [[ ${HADOOP_CLIENT} == MAPR ]]; then
		# start mapr services before installing GPDB
		/root/init-script
	fi

	# Ping is called by gpinitsystem, which must be run by gpadmin
	chmod u+s /bin/ping

	# Install GPDB
	install_gpdb_binary
	setup_gpadmin_user

	# Install PXF
	install_pxf_client
	install_pxf_server

	if [[ -z ${PROTOCOL} && ! ${HADOOP_CLIENT} == MAPR ]]; then
		# Setup Hadoop before creating GPDB cluster to use system python for yum install
		setup_hadoop "${GPHD_ROOT}"
	fi

	create_gpdb_cluster
	add_remote_user_access_for_gpdb testuser
	init_and_configure_pxf_server

	if [[ ${HADOOP_CLIENT} == MAPR ]]; then
		configure_mapr_dependencies
	elif [[ -z ${PROTOCOL} ]]; then
		configure_pxf_default_server
		configure_pxf_s3_server
	fi
	start_pxf_server

	# Create fat jar for automation
	generate_extras_fat_jar

	if [[ ${ACCEPTANCE} == true ]]; then
		echo 'Acceptance test pipeline'
		exit 1
	fi

	# Run Tests
	if [[ -n ${GROUP} ]]; then
		time run_pxf_automation
	fi
}

_main
