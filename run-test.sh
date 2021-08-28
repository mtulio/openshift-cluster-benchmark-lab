#!/bin/bash

#
# [WIP] script to create lab OCP environment on AWS to provision master with two volumes,
# and mount the second on ETCD.
# The main objective is to validate gp3 volume type on etcd.
# References:
#  - https://github.com/mtulio/installer/pull/4 : minor changes will be applied to 
#    match help to the test: Detailed monitoring, EBS-Optimized, etc
#  - SPLAT254
#

set -ex

if [[ -f ./.env ]]; then
  source ./.env
fi

test -z $1 && ( echo "Test ID ARG#1 was not found. Eg: t1, t2...  )"; exit 1 )

TID=$1
TNAME="mrb254${TID:0:2}"
TDIR="aws-${TNAME}"
RELEASE="${2:-"4.9"}"

declare -g OC_CLI="./oc-${RELEASE} --kubeconfig ${TDIR}/auth/kubeconfig "

declare -g DEFAULT_VOL_TYPE="gp2";
declare -g DEFAULT_VOL_SIZE="128";
declare -g EC2_SIZE_MASTER="m5.xlarge";
declare -g EC2_SIZE_WORKER="${EC2_SIZE_MASTER}";

# limit params (see case/esac)
if [[ ( ${#TID} -lt 2 ) || ( ${#TID} -gt 3 ) ]]; then
  echo "Invalid param [${TID}] . Valid are: TID=\"t[0-9](|d)\"";
  exit 1
fi

# odd tests will run with only disk (hardcoded on installer)
# To build the installer, check those changes:
# https://github.com/mtulio/installer/pull/4/files#diff-1d1c6cd6df20b7e2fd321d88255bb4dfc9cbbe4289ee324829f5fc03ac977c9dR167-R174
if [[ $(echo "${TID:1:2} % 2" | bc) -eq 0 ]]; then
  # the second EBS will inherit the same attributos of rootVolume (from install-config)
  INSTALLER="./openshift-install-4.9-gp3m6i-monit-ebsOpt-2xEBS"
else
  # the lines above must be commented to create this binary (1xEBS)
  INSTALLER="./openshift-install-4.9-gp3m6i-monit-ebsOpt-1xEBS"
fi


#
setup_test() {
  mkdir -p $TDIR
  cp ${TDIR}_install-config.yaml ${TDIR}/install-config.yaml
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="registry.ci.openshift.org/ocp/release:${RELEASE}"
}

# patch machine providerSpec object to add new EBS
generate_machine_devBlocks() {
  TMPDIR=$(mktemp)
  rm -f ${TMPDIR}
  mkdir -p ${TMPDIR}

  for MACHINE in $(ls ${TDIR}/openshift/99_openshift-cluster-api_master-machines-*.yaml); do 
    
    echo $MACHINE;
    MACHINE_FILE=$(basename $MACHINE)
    
    # extract header (pre blockDevices)
    sed '1,/blockDevices/!d' ${MACHINE} > ${TMPDIR}/${MACHINE_FILE}_00

    # duplicate device list block
    cat << EOF > ${TMPDIR}/${MACHINE_FILE}_01-devs
      - ebs:
          encrypted: true
          iops: 0
          kmsKey:
            arn: ""
          volumeType: ${1:-"${DEFAULT_VOL_TYPE}"}
          volumeSize: ${2:-"${DEFAULT_VOL_SIZE}"}
      - deviceName: /dev/xvdb
        ebs:
          encrypted: true
          iops: 0
          kmsKey:
            arn: ""
          volumeType: ${1:-"${DEFAULT_VOL_TYPE}"}
          volumeSize: ${2:-"${DEFAULT_VOL_SIZE}"}

EOF
    # extract footer (post blockDevices
    grep credentialsSecret -A 999 ${MACHINE} > ${TMPDIR}/${MACHINE_FILE}_03

    # join files
    cat ${TMPDIR}/${MACHINE_FILE}_* > ${TMPDIR}/${MACHINE_FILE}

    echo "Aggregated file created on ${TMPDIR}/${MACHINE_FILE} , overwriting to $MACHINE"
    cp ${TMPDIR}/${MACHINE_FILE} $MACHINE
  done
  # TODO remove it when script is ready
  #rm -rf ${TMPDIR}
}

create_cluster() {
  setup_test
  ${INSTALLER} --dir $TDIR create cluster
}

create_manifests() {
  setup_test
  rm -rf $TDIR/openshift $TDIR/manifests
  ${INSTALLER} --dir $TDIR create manifests
}

create_ignitions() {
  ${INSTALLER} --dir $TDIR create ignition-configs
}

create_manifests_for_etcd() {
  create_manifests
  generate_machine_devBlocks
  #cp 99_openshift-machineconfig_00-master-etcd.yaml $TDIR/openshift/
  # https://docs.fedoraproject.org/en-US/fedora-coreos/storage/
  # https://coreos.github.io/butane/examples/#mirrored-boot-disk
  cat << EOF > $TDIR/openshift/99_openshift-machineconfig_00-master-etcd.yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 00-master-etcd
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      disks:
      - device: /dev/nvme1n1
        wipe_table: true
        partitions:
        - size_mib: 0
          label: etcd
      filesystems:
        - path: /var/lib/etcd
          device: /dev/disk/by-partlabel/etcd
          format: xfs
          wipe_filesystem: true
    systemd:
      units:
        - name: var-lib-etcd.mount
          enabled: true
          contents: |
            [Unit]
            Before=local-fs.target
            [Mount]
            Where=/var/lib/etcd
            What=/dev/disk/by-partlabel/etcd
            [Install]
            WantedBy=local-fs.target
EOF
}

create_cluster_for_etcd() {
  create_manifests_for_etcd
  create_ignitions
  ${INSTALLER} --dir $TDIR create cluster
}

destroy_cluster() {
  ${INSTALLER} --dir $TDIR destroy cluster
}


create_install_config_aws() {

  # Check env 
  if [[ -z ${PULL_SECRET} ]]; then
    echo "Environment var is not defined: PULL_SECRET. Exiting...";
    exit 1;
  fi

  if [[ -z ${SSH_PUB_KEYS} ]]; then
    echo "Environment var is not defined: SSH_PUB_KEYS. Exiting...";
    exit 1;
  fi

  VOL_TYPE="${1:-"${DEFAULT_VOL_TYPE}"}"
  VOL_SIZE="${2:-"${DEFAULT_VOL_SIZE}"}"

  install_config="${TDIR}_install-config.yaml"
  cat << EOF > ${install_config}
apiVersion: v1
baseDomain: devcluster.openshift.com
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform:
    aws:
      type: ${EC2_SIZE_WORKER}
      rootVolume:
        size: ${2:-"${DEFAULT_VOL_SIZE}"}
        type: ${1:-"${DEFAULT_VOL_TYPE}"}
  replicas: 3
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    aws:
      type: ${EC2_SIZE_MASTER}
      rootVolume:
        size: ${2:-"${DEFAULT_VOL_SIZE}"}
        type: ${1:-"${DEFAULT_VOL_TYPE}"}
  replicas: 3
metadata:
  creationTimestamp: null
  name: mrb254${TID}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: us-east-1
publish: External
pullSecret: '${PULL_SECRET}'
sshKey: |
  ${SSH_PUB_KEYS}

EOF
}

run_test_fio() {
  echo "DO NOTHING"
  # etcd fio
  # for NODE in $(oc get nodes -l node-role.kubernetes.io/master=  -o jsonpath='{.items[*].metadata.name}'); do \
  #   echo "node/${NODE}"; \
  #   oc debug node/${NODE} -- chroot /host /bin/bash -c "podman run --volume /var/lib/etcd:/var/lib/etcd:Z quay.io/openshift-scale/etcd-perf"; \
  # done

  # other fio opts / Refs:
  #  - https://github.com/jcpowermac/etcd-thin-vs-thick-perf-test/blob/main/fio.sh
  #  - https://hub.docker.com/r/ljishen/fio

}

run_fio() {

  # temp here:
  OC_CLI="./oc-${RELEASE} --kubeconfig ${TDIR}/auth/kubeconfig "

  echo "#> Checking disk topology"
  for EN in $($OC_CLI get nodes -l node-role.kubernetes.io/master= -o jsonpath='{.items[0].metadata.name}'); do
    echo "#> NODE=${EN}"
    ${OC_CLI} debug node/${EN} -- chroot /host /bin/bash -c "lsblk" 2>/dev/null
  done

  # choosing one node to take the test. TODO: give option to test to all nodes in parallel
  NODE=$($OC_CLI get nodes -l node-role.kubernetes.io/master= -o jsonpath='{.items[0].metadata.name}')

  echo "Running tests as user [$($OC_CLI whoami)] to API [$($OC_CLI whoami --show-server)] and node [${NODE}]"
  ${OC_CLI} debug node/${NODE} -- chroot /host /bin/bash -c \
    "TEST_DIR=\"/var/lib/etcd/_benchmark\"; \
     mkdir -p \$TEST_DIR; \
     for l in {a..j} ; do \
      for i in {1..10} ; do \
        echo \"[\$l][\$i] <=> \$(hostname) <=> \$(date) <=> \$(uptime) \"; \
        podman run --rm \
          -v \$TEST_DIR:\$TEST_DIR:Z \
          ljishen/fio --rw=write \
                      --ioengine=sync \
                      --fdatasync=1 \
                      --size=200m \
                      --bs=2300 \
                      --directory=\"\$TEST_DIR\" \
                      --name=\"fio_io_\${l}\${i}\" \
                      --output-format=json \
                      --output=\"\$TEST_DIR/fio_results_write_\${l}\${i}.json\" ;\
        sleep 10; \
        ls -lsh \$TEST_DIR/; \
        rm -f \$TEST_DIR/fio_io_\${l}\${i}* ||true ; \
      done; \
    done; \
    tar cfz \${TEST_DIR}_results.tar.gz \
      \${TEST_DIR}*/*.json" 2>/dev/null |tee -a results/fio_stdout-${TID}-${NODE}.txt

    # Run etcd-fio (right after all FIO burn)
    ${OC_CLI} debug node/${NODE} -- chroot /host /bin/bash -c \
      "podman run \
        --volume /var/lib/etcd:/var/lib/etcd:Z \
        quay.io/openshift-scale/etcd-perf" > results/fio_etcd-${TID}.txt ;

    # collect results
    ${OC_CLI} debug node/${NODE} -- chroot /host /bin/bash -c \
      "tar cfz /var/lib/etcd/_benchmark_results.tar.gz /var/lib/etcd/_benchmark*/*.json"
    
    #mkdir -p results/fio-${TID}-${NODE}
    echo "#> Collecting results up PrometheusDB"
    ${OC_CLI} debug node/${NODE} -- chroot /host /bin/bash -c \
      "cat /var/lib/etcd/_benchmark_results.tar.gz" 2>/dev/null > results/fio-${TID}-${NODE}.tar.gz

    # Prometheus DB
    echo "#> Waiting 5m to collect PrometheusDB..."
    sleep 300
    mkdir -p results/fio-${TID}-prometheus
    ${OC_CLI} rsync -c prometheus -n openshift-monitoring \
      pod/prometheus-k8s-0:/prometheus/ results/fio-${TID}-prometheus
    tar cfJ results/fio-${TID}-prometheus.tar.xz results/fio-${TID}-prometheus
    test -f results/fio-${TID}-prometheus.tar.xz && rm -rf results/fio-${TID}-prometheus

}

run_fio_master() {
  MASTER_NODE=$1

}

#
# t1-2 : m5+gp2
# t3-4 : m5+gp3
# t5-6 : m5+gp3  # 64G
# t7-8 : m6i+gp3 # 64G
#
case $TID in
  # m5.xlarge 1x gp2 128G
  "t1") create_install_config_aws; 
        create_cluster;
      ;;
  # m5.xlarge 2x gp2 128G
  #> provisioner
  "t2") create_install_config_aws;
        create_cluster_for_etcd;
      ;;
  #> runner
  "t2r") run_fio;
      ;;
  # m5.xlarge 1x gp3 128G
  "t3") DEFAULT_VOL_TYPE="gp3";
        create_install_config_aws;
        create_cluster ;;
  # m5.xlarge 2x gp3 128G
  #> provisioner
  "t4") DEFAULT_VOL_TYPE="gp3";
        create_install_config_aws;
        create_cluster_for_etcd;
      ;;
  #> runner
  "t4r") run_fio;
      ;;
  # m5.xlarge 1x gp3 64G
  "t5") DEFAULT_VOL_TYPE="gp3";
        DEFAULT_VOL_SIZE="64";
        create_install_config_aws;
        create_cluster;
      ;;
  # m5.xlarge 2x gp3 64G
  "t6") DEFAULT_VOL_TYPE="gp3";
        DEFAULT_VOL_SIZE="64";
        create_install_config_aws;
        create_cluster_for_etcd;
      ;;
  # m6i.xlarge 1x gp3 64G
  "t7") EC2_SIZE_MASTER="m6i.xlarge";
        EC2_SIZE_WORKER="${EC2_SIZE_MASTER}";
        DEFAULT_VOL_TYPE="gp3";
        DEFAULT_VOL_SIZE="64";
        create_install_config_aws;
        create_cluster;
      ;;
  # m6i.xlarge 2x gp3 64G
  "t8") EC2_SIZE_MASTER="m6i.xlarge";
        EC2_SIZE_WORKER="${EC2_SIZE_MASTER}";
        DEFAULT_VOL_TYPE="gp3";
        DEFAULT_VOL_SIZE="64";
        create_install_config_aws;
        create_cluster_for_etcd;
      ;;
  # Destroy a cluster 
  "t1d") destroy_cluster ;;
  "t2d") destroy_cluster ;;
  "t3d") destroy_cluster ;;
  "t4d") destroy_cluster ;;
  "t6d") destroy_cluster ;;
  *) echo "Test ID not found. Available t{1..6}(|d)" ;;
esac