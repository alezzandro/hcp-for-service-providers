# install-config.yaml template for the Hub cluster (ACM + MCE + HyperShift)
#
# Render with envsubst before use:
#   export BASE_DOMAIN AWS_REGION CLUSTER_NAME PULL_SECRET SSH_KEY
#   export PRIVATE_SUBNETS PUBLIC_SUBNETS
#   envsubst < hub-install-config.yaml.tpl > hub/install-config.yaml
#
# The cluster is a 3-node compact (masters schedulable, no workers).
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
      type: m5.2xlarge
      rootVolume:
        size: 250
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
