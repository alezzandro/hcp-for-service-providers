# Secondary ENIs are created and attached post-install by setup/04-attach-secondary-nic.sh
# because the bare-metal EC2 instance IDs are only known after OCP IPI completes.
#
# This file outputs the subnet and security group IDs needed by that script.
#
# The script workflow:
#   1. Discover bare-metal instance IDs (from OCP Machine objects or AWS tags)
#   2. For each instance, determine its AZ
#   3. Create an ENI in the matching tenant subnet with the tenant SG
#   4. Attach the ENI to the instance
#   5. Disable source/dest check on the ENI
