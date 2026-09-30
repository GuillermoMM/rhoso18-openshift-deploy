#!/usr/bin/env bash
# Deploys the RHOSO 18.0 control plane on OpenShift 4.20, step by step, with verification.
# Usage: ./deploy.sh [list | all | verify | <step-id>...]
set -euo pipefail

cd "$(dirname "$0")"
M=manifests
ENABLE_ISCSI_CHAP=${ENABLE_ISCSI_CHAP:-false}

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32mOK:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { printf '\033[0;36m$ %s\033[0m\n' "$*"; "$@"; }

apply()  { run oc apply -f "$M/$1" "${@:2}"; }
ensure_ns() { oc create namespace "$1" --dry-run=client -o yaml | oc apply -f -; }

# wait_until <timeout-seconds> <description> <command...>
wait_until() {
  local timeout=$1 desc=$2; shift 2
  local end=$((SECONDS + timeout))
  printf 'Waiting for %s (timeout %ss)' "$desc" "$timeout"
  until "$@" >/dev/null 2>&1; do
    (( SECONDS >= end )) && { echo; die "timed out waiting for $desc"; }
    printf '.'; sleep 10
  done
  echo; ok "$desc"
}

csv_succeeded() {
  oc get csv -n "$1" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' \
    | grep -q "^$2[^ ]* Succeeded$"
}
wait_csv() { wait_until "${3:-900}" "CSV $2 in $1 to be Succeeded" csv_succeeded "$1" "$2"; }

wait_crd() {
  wait_until "${2:-600}" "CRD $1" oc get crd "$1"
  oc wait --for=condition=Established "crd/$1" --timeout=120s >/dev/null
}

# ---------------------------------------------------------------- steps

deploy_preflight() {
  command -v oc >/dev/null || die "oc not found in PATH"
  run oc whoami
  run oc get clusterversion
  run oc get nodes
}
verify_preflight() {
  oc get clusterversion
  oc get co | awk 'NR==1 || $3!="True" || $4!="False" || $5!="False"'
  oc get nodes
}

deploy_010() {
  apply 010-openstack-operator/010-openstack-operator-ns.yaml
  apply 010-openstack-operator/020-operator-group.yaml
  apply 010-openstack-operator/030-Subscription.yaml
  # The subscription uses installPlanApproval: Manual, so approve pending plans until the CSV succeeds.
  local end=$((SECONDS + 900)) ip
  until csv_succeeded openstack-operators openstack-operator; do
    ip=$(oc get installplan -n openstack-operators \
      -o jsonpath='{range .items[?(@.spec.approved==false)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1 || true)
    [[ -n $ip ]] && run oc patch installplan "$ip" -n openstack-operators --type merge -p '{"spec":{"approved":true}}'
    (( SECONDS >= end )) && die "timed out waiting for openstack-operator CSV"
    sleep 10
  done
  run oc wait csv -n openstack-operators \
    -l operators.coreos.com/openstack-operator.openstack-operators="" \
    --for jsonpath='{.status.phase}'=Succeeded --timeout=300s
}
verify_010() {
  oc get subscription,installplan -n openstack-operators
  oc get csv -n openstack-operators | grep -E "NAME|openstack-operator"
}

deploy_020() {
  ensure_ns cert-manager-operator
  apply 020-cert-manager/010-operator-group.yaml
  apply 020-cert-manager/020-subscription-cert-manager-operator.yaml
  wait_csv cert-manager-operator cert-manager-operator
  wait_crd issuers.cert-manager.io
  wait_crd certificates.cert-manager.io
  wait_until 600 "cert-manager-webhook deployment" oc get deploy cert-manager-webhook -n cert-manager
  run oc wait deploy --all -n cert-manager --for=condition=Available --timeout=600s
}
verify_020() {
  oc get installplan -n cert-manager-operator
  oc get csv -n cert-manager-operator | grep -E "NAME|cert-manager"
  oc get pods -n cert-manager-operator
  oc get pods -n cert-manager
  oc get crd issuers.cert-manager.io certificates.cert-manager.io
}

deploy_030() {
  apply 010-openstack-operator/040-instance-openstack-operator.yaml
  run oc wait openstack/openstack -n openstack-operators --for condition=Ready --timeout=900s
}
verify_030() {
  oc get openstack -n openstack-operators
  oc get csv -n openstack-operators
}

deploy_035() {
  ensure_ns openstack
  run oc label ns openstack security.openshift.io/scc.podSecurityLabelSync=false --overwrite
  run oc label ns openstack pod-security.kubernetes.io/enforce=privileged --overwrite
}
verify_035() {
  oc get namespace openstack -o jsonpath='{.metadata.labels}{"\n"}'
}

deploy_040() {
  local f=$M/040-secrets/openstack_service_secret.yaml
  [[ -f $f ]] || die "$f not found. Copy openstack_service_secret.example.yaml to it and set the passwords (see README)."
  grep -q CHANGE_ME "$f" && die "$f still contains CHANGE_ME placeholders."
  run oc apply -f "$f"
}
verify_040() {
  oc get secret osp-secret -n openstack
}

deploy_041() {
  apply 041-iscsi-chap/99-master-iscsi-chap-algs.json
  log "Nodes will drain and reboot one at a time"
  wait_until 300 "master pool to start updating" \
    sh -c "oc get mcp master -o jsonpath='{.status.conditions[?(@.type==\"Updating\")].status}' | grep -q True"
  run oc wait mcp/master --for=condition=Updated --timeout=90m
}
verify_041() {
  oc get mcp master
  for n in $(oc get nodes -o name); do
    echo "== ${n#node/}"
    oc debug "$n" -q -- chroot /host sh -c \
      'grep "^node.session.auth.chap_algs" /etc/iscsi/iscsid.conf; echo "fips_enabled=$(cat /proc/sys/crypto/fips_enabled)"' 2>/dev/null
  done
}

deploy_045() {
  ensure_ns openshift-nmstate
  run oc label namespace openshift-nmstate pod-security.kubernetes.io/enforce=privileged --overwrite
  apply 045-nmstate/020-operator-group.yaml
  apply 045-nmstate/030-subscription.yaml
  wait_csv openshift-nmstate kubernetes-nmstate-operator
  wait_crd nmstates.nmstate.io
  apply 045-nmstate/040-nmstate-instance.yaml
  wait_crd nodenetworkstates.nmstate.io
  wait_until 600 "nmstate-handler daemonset" oc get ds nmstate-handler -n openshift-nmstate
  run oc rollout status ds/nmstate-handler -n openshift-nmstate --timeout=600s
}
verify_045() {
  oc get subscription,csv,installplan -n openshift-nmstate
  oc get crd nodenetworkstates.nmstate.io
  oc get nns
}

deploy_050() {
  apply 050-networks/osp-master-1.yaml
  apply 050-networks/osp-master-2.yaml
  apply 050-networks/osp-master-3.yaml
  run oc wait nncp --all --for condition=Available --timeout=600s
}
verify_050() {
  oc get nncp
  oc get nnce
}

deploy_060() {
  apply 060-network-attachment-definitions/openstack-net-attach-def.yaml
}
verify_060() {
  oc get net-attach-def -n openstack
}

deploy_070() {
  apply 070-metallb/010-install-metallb-operator.yaml
  wait_csv metallb-system metallb-operator
  wait_crd metallbs.metallb.io
  apply 070-metallb/020-metallb-instance.yaml
  wait_crd ipaddresspools.metallb.io
  wait_until 600 "MetalLB controller deployment" oc get deploy controller -n metallb-system
  run oc wait deploy/controller -n metallb-system --for=condition=Available --timeout=600s
  apply 070-metallb/openstack-ipaddresspools.yaml
}
verify_070() {
  oc get csv -n metallb-system | grep -E "NAME|metallb"
  oc get crd ipaddresspools.metallb.io
  oc get pods -n metallb-system
  oc get ipaddresspool -n metallb-system
}

deploy_080() {
  apply 080-l2advertisement/openstack-l2advertisement.yaml
}
verify_080() {
  oc get l2advertisement -n metallb-system
}

deploy_090() {
  apply 090-netconfig/openstack_netconfig.yaml -n openstack
}
verify_090() {
  oc get netconfig/openstacknetconfig -n openstack
}

deploy_095() {
  apply 095-cluster-observability/010-cluster-observability-operator.yaml
  wait_csv openshift-cluster-observability-operator cluster-observability-operator
  wait_crd monitoringstacks.monitoring.rhobs
}
verify_095() {
  oc get csv -n openshift-cluster-observability-operator | grep -E "NAME|cluster-observability"
  oc get crd monitoringstacks.monitoring.rhobs
}

deploy_096() {
  apply 096-storage-lvms/010-lvm-operator.yaml
  wait_csv openshift-storage lvms-operator
  wait_crd lvmclusters.lvm.topolvm.io
  apply 096-storage-lvms/020-lvm-cluster.yaml
  run oc wait lvmcluster/lvmcluster -n openshift-storage --for=jsonpath='{.status.state}'=Ready --timeout=900s
  wait_until 300 "StorageClass lvms-vg1" oc get storageclass lvms-vg1
}
verify_096() {
  oc get csv -n openshift-storage | grep -E "NAME|lvms"
  oc get lvmcluster -n openshift-storage
  oc get storageclass
}

deploy_100() {
  apply 100-control-plane/openstack_control_plane.yaml -n openstack
  log "The control plane can take 30+ minutes to become Ready"
  run oc wait openstackcontrolplane/openstack-control-plane -n openstack --for condition=Ready --timeout=90m
}
verify_100() {
  oc get openstackcontrolplane -n openstack
  oc get pods -n openstack --no-headers | awk '$3!="Running" && $3!="Completed"' | sed 's/^/not running: /'
  oc exec -n openstack openstackclient -- openstack endpoint list
}

deploy_500() {
  local d=$M/500-dataplane-secrets f
  [[ -f $d/generic_key ]] || run ssh-keygen -f "$d/generic_key" -N "" -t rsa -b 4096
  [[ -f $d/nova-migration-ssh-key ]] || run ssh-keygen -f "$d/nova-migration-ssh-key" -N "" -t ecdsa -b 521
  oc create secret generic dataplane-ansible-ssh-private-key-secret -n openstack \
    --save-config --dry-run=client \
    --from-file=ssh-privatekey="$d/generic_key" \
    --from-file=ssh-publickey="$d/generic_key.pub" -o yaml | oc apply -f -
  oc create secret generic nova-migration-ssh-key -n openstack \
    --save-config --dry-run=client \
    --from-file=ssh-privatekey="$d/nova-migration-ssh-key" \
    --from-file=ssh-publickey="$d/nova-migration-ssh-key.pub" -o yaml | oc apply -f -
  for f in subscription-secret registry-secret libvirt-secret; do
    [[ -f $d/$f.yaml ]] || die "$d/$f.yaml not found. Copy $f.example.yaml to it and fill it in (see README)."
    grep -q CHANGE_ME "$d/$f.yaml" && die "$d/$f.yaml still contains CHANGE_ME placeholders."
    run oc apply -f "$d/$f.yaml"
  done
}
verify_500() {
  oc get secret -n openstack dataplane-ansible-ssh-private-key-secret nova-migration-ssh-key \
    subscription-manager redhat-registry libvirt-secret
}

# ---------------------------------------------------------------- driver

STEPS=(
  "preflight|Check cluster access and health"
  "010|Install the OpenStack operator (approve manual InstallPlan)"
  "020|Install cert-manager"
  "030|Create the OpenStack operator instance"
  "035|Create and label the openstack namespace"
  "040|Create osp-secret (service passwords)"
  "041|OPTIONAL: iSCSI CHAP algorithms MachineConfig (reboots nodes; ENABLE_ISCSI_CHAP=true)"
  "045|Install NMState operator and instance"
  "050|Apply NodeNetworkConfigurationPolicies"
  "060|Create NetworkAttachmentDefinitions"
  "070|Install MetalLB and IPAddressPools"
  "080|Create L2Advertisements"
  "090|Create NetConfig"
  "095|Install Cluster Observability Operator (telemetry)"
  "096|Install LVM Storage and StorageClass lvms-vg1"
  "100|Deploy the OpenStackControlPlane"
  "500|Create data plane (compute) secrets"
)

step_ids() { local s; for s in "${STEPS[@]}"; do echo "${s%%|*}"; done; }

run_step() {
  local id=$1
  declare -F "deploy_$id" >/dev/null || die "unknown step '$id' (see ./deploy.sh list)"
  log "Step $id: deploy"
  "deploy_$id"
  log "Step $id: verify"
  "verify_$id"
}

usage() {
  cat <<EOF
Usage: $0 [list | all | verify | <step-id>...]
  list      show the steps
  all       run every step in order (041 only if ENABLE_ISCSI_CHAP=true)
  verify    run only the read-only verification of every step
  <id>...   run specific steps, e.g. $0 070 080
EOF
}

main() {
  [[ $# -eq 0 ]] && { usage; exit 0; }
  case $1 in
    -h|--help) usage ;;
    list) local s; for s in "${STEPS[@]}"; do printf '  %-10s %s\n' "${s%%|*}" "${s#*|}"; done ;;
    all)
      local id
      for id in $(step_ids); do
        [[ $id == 041 && $ENABLE_ISCSI_CHAP != true ]] && { log "Skipping 041 (ENABLE_ISCSI_CHAP!=true)"; continue; }
        run_step "$id"
      done
      log "Deployment finished" ;;
    verify)
      local id
      for id in $(step_ids); do log "Verify $id"; ( set +e; "verify_$id" ) || true; done ;;
    *) local id; for id in "$@"; do run_step "$id"; done ;;
  esac
}

main "$@"
