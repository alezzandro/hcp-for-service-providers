# install-config.yaml template for the Infrastructure cluster (OCP Virt, bare-metal)
#
# Render with envsubst before use:
#   export BASE_DOMAIN AWS_REGION CLUSTER_NAME PULL_SECRET SSH_KEY
#   export PRIVATE_SUBNETS PUBLIC_SUBNETS
#   envsubst < virt-install-config.yaml.tpl > virt/install-config.yaml
#
# The cluster is a 3-node compact on m5.metal bare-metal instances.
# Masters are schedulable (no dedicated workers) so OCP Virt VMs
# run directly on the master nodes.
---
apiVersion: v1
metadata:
  name: ${CLUSTER_NAME}
baseDomain: ${BASE_DOMAIN}
networking:
  networkType: OVNKubernetes
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  serviceNetwork:
    - 172.30.0.0/16
  machineNetwork:
    - cidr: 10.0.0.0/16
controlPlane:
  name: master
  replicas: 3
  platform:
    aws:
      type: m5.metal
      rootVolume:
        size: 500
        type: gp3
compute:
  - name: worker
    replicas: 0
platform:
  aws:
    region: ${AWS_REGION}
    subnets:
${PRIVATE_SUBNETS}
${PUBLIC_SUBNETS}
publish: External
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_KEY}'
