# Prerequisites

## AWS Account

- An AWS account with permissions to create:
  - VPC, subnets, internet gateway, NAT gateway, route tables
  - EC2 instances including `m5.metal` bare-metal instances
  - Elastic Network Interfaces (ENI)
  - Route53 hosted zones and records
  - Security groups
  - IAM users/roles (for `openshift-install`)
  - S3 buckets (used internally by `openshift-install`)
  - Elastic Load Balancers (created by `openshift-install`)
- Service quotas:
  - At least 3× `m5.metal` instances (or your chosen bare-metal type)
  - At least 3× `m5.2xlarge` instances
  - Sufficient EBS volume quota for both clusters
  - Sufficient Elastic IP quota (at least 2 for NAT gateways)

## DNS

- A Route53 public hosted zone for your base domain (e.g., `example.com`)
- The `openshift-install` tool will create sub-zones for each cluster
  (e.g., `hub.example.com`, `virt.example.com`)

## Required Tools

| Tool | Minimum Version | Purpose |
|------|-----------------|---------|
| `aws` | 2.x | AWS CLI for infrastructure operations |
| `terraform` | 1.5+ | Infrastructure as Code for VPC/networking |
| `openshift-install` | 4.21+ | OCP cluster installation |
| `oc` | 4.21+ | OpenShift CLI |
| `hcp` | — | HyperShift CLI (from MCE) |
| `jq` | 1.6+ | JSON processing in scripts |
| `envsubst` | — | Template rendering (part of `gettext`) |

### Installing the `hcp` CLI

The `hcp` CLI is distributed with the MCE operator. After installing ACM/MCE
on the hub cluster, download it:

```bash
oc get ConsoleCLIDownload hcp-cli-download -o json | \
  jq -r '.spec.links[] | select(.text | contains("Linux")) | .href' | \
  xargs curl -sL -o /usr/local/bin/hcp
chmod +x /usr/local/bin/hcp
```

Alternatively, build from the
[HyperShift repository](https://github.com/openshift/hypershift).

## Required Files

Place these in the `demo/` root directory before running setup:

| File | Description | How to Obtain |
|------|-------------|---------------|
| `credentials.env` | AWS credentials, region, Route53 domain/zone | `cp credentials.env.example credentials.env` then edit |
| `pull-secret.json` | Red Hat pull secret | [console.redhat.com/openshift/install/pull-secret](https://console.redhat.com/openshift/install/pull-secret) |
| `id_rsa.pub` | SSH public key | `ssh-keygen -t rsa -b 4096` |

All three files are git-ignored and must never be committed.

## AWS Credentials (credentials.env)

All AWS credentials and lab-specific parameters go in `credentials.env`.
Every setup script sources this file automatically.

```bash
cp credentials.env.example credentials.env
vi credentials.env
```

The file contains:

| Variable | Description |
|----------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |
| `AWS_DEFAULT_REGION` | AWS region (e.g. `us-east-2`) |
| `AWS_ACCOUNT_ID` | AWS account ID |
| `BASE_DOMAIN` | Route53 base domain (e.g. `sandbox1234.opentlc.com`) |

The Route53 hosted zone ID is resolved automatically from `BASE_DOMAIN` by
the setup scripts — you do not need to provide it.

For OPENTLC/RHPDS sandbox environments, these values are provided in your
lab provisioning email. The `BASE_DOMAIN` is the sandbox domain **without**
a leading dot (e.g., `sandbox1234.opentlc.com`, not `.sandbox1234.opentlc.com`).

`terraform.tfvars` is auto-generated from `credentials.env` by the setup
scripts — you do not need to create it manually.

## Network Requirements

- The workstation running the setup scripts needs internet access
- Both OCP clusters need internet access (for image pulls, operator installs)
- The hub cluster's API and ingress endpoints must be reachable from the
  infra cluster (for Konnectivity tunnels)
