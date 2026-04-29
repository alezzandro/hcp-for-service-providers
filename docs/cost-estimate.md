# AWS Cost Estimate

## Hourly Costs (On-Demand, us-east-2)

| Component | Type | Count | $/hr Each | $/hr Total |
|-----------|------|-------|-----------|------------|
| Hub cluster masters | m5.2xlarge | 3 | $0.384 | $1.15 |
| Infra cluster masters | m5.metal | 3 | $4.608 | $13.82 |
| EBS volumes (gp3) | ~500 GiB total | — | — | ~$0.50 |
| NAT Gateway | — | 1 | $0.045 | $0.045 |
| NAT Gateway data | ~10 GB/hr est. | — | — | ~$0.45 |
| Elastic Load Balancers | NLB | 4 | $0.0225 | $0.09 |
| Route53 hosted zone | — | 1 | — | negligible |
| **Total** | | | | **~$16/hr** |

## Daily / Weekly Projections

| Duration | Estimated Cost |
|----------|---------------|
| 1 hour | ~$16 |
| 8 hours (workday) | ~$128 |
| 24 hours | ~$384 |
| 1 week | ~$2,688 |

## Cost Reduction Options

### Use c5.metal Instead of m5.metal

`c5.metal` instances have 192 GiB RAM (vs. 384 GiB for m5.metal) at
$4.080/hr each. For a demo with 4 small VMs (8 GiB each), 192 GiB per
node is more than sufficient.

| | m5.metal | c5.metal | Savings |
|---|----------|----------|---------|
| $/hr (3 nodes) | $13.82 | $12.24 | $1.58/hr |
| $/day (3 nodes) | $331.78 | $293.76 | $38/day |

### Use Spot Instances

AWS bare-metal Spot instances can offer 60-90% savings. However:
- Spot capacity for `*.metal` types is limited
- Spot interruptions would disrupt the demo
- Best for non-production testing, not live demos

### Destroy When Not in Use

The single most effective cost control: **always run `uninstall-demo.sh`
when finished.** A forgotten environment costs ~$384/day.

```bash
# Full teardown
./setup/uninstall-demo.sh

# Verify nothing is left
aws ec2 describe-instances \
  --filters "Name=tag:demo,Values=hcp-network-isolation" \
  --query 'Reservations[].Instances[].InstanceId'
```

## What openshift-install Creates

Each `openshift-install create cluster` invocation creates AWS resources
that are tracked in the cluster's metadata directory. The `openshift-install
destroy cluster` command cleans them up. Resources include:

- EC2 instances (master/worker nodes)
- Elastic Load Balancers (API + ingress)
- Security groups
- IAM roles and instance profiles
- S3 bucket (for bootstrap ignition)
- Route53 records (within the cluster's sub-zone)
- EBS volumes

The Terraform module creates the shared VPC, subnets, and Route53 base
zone separately; `terraform destroy` cleans those up.
