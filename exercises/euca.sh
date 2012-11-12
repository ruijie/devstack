#!/usr/bin/env bash

# **euca.sh**

# we will use the ``euca2ools`` cli tool that wraps the python boto
# library to test ec2 compatibility

echo "*********************************************************************"
echo "Begin DevStack Exercise: $0"
echo "*********************************************************************"

# This script exits on an error so that errors don't compound and you see
# only the first error that occured.
set -o errexit

# Print the commands being run so that we can see the command that triggers
# an error.  It is also useful for following allowing as the install occurs.
set -o xtrace


# Settings
# ========

# Keep track of the current directory
EXERCISE_DIR=$(cd $(dirname "$0") && pwd)
TOP_DIR=$(cd $EXERCISE_DIR/..; pwd)
VOLUME_SIZE=1
ATTACH_DEVICE=/dev/vdc

# Import common functions
source $TOP_DIR/functions

# Import EC2 configuration
source $TOP_DIR/eucarc

# Import exercise configuration
source $TOP_DIR/exerciserc

# Instance type to create
DEFAULT_INSTANCE_TYPE=${DEFAULT_INSTANCE_TYPE:-m1.tiny}

# Boot this image, use first AMI-format image if unset
DEFAULT_IMAGE_NAME=${DEFAULT_IMAGE_NAME:-ami}

# Security group name
SECGROUP=${SECGROUP:-euca_secgroup}


# Launching a server
# ==================

# Find a machine image to boot
IMAGE=`euca-describe-images | grep machine | grep ${DEFAULT_IMAGE_NAME} | cut -f2 | head -n1`

# Add a secgroup
if ! euca-describe-groups | grep -q $SECGROUP; then
    euca-add-group -d "$SECGROUP description" $SECGROUP
    if ! timeout $ASSOCIATE_TIMEOUT sh -c "while ! euca-describe-groups | grep -q $SECGROUP; do sleep 1; done"; then
        echo "Security group not created"
        exit 1
    fi
fi

# Launch it
INSTANCE=`euca-run-instances -g $SECGROUP -t $DEFAULT_INSTANCE_TYPE $IMAGE | grep INSTANCE | cut -f2`
die_if_not_set INSTANCE "Failure launching instance"

# Assure it has booted within a reasonable time
if ! timeout $RUNNING_TIMEOUT sh -c "while ! euca-describe-instances $INSTANCE | grep -q running; do sleep 1; done"; then
    echo "server didn't become active within $RUNNING_TIMEOUT seconds"
    exit 1
fi

# Volumes
# -------
if [[ "$ENABLED_SERVICES" =~ "n-vol" || "$ENABLED_SERVICES" =~ "c-vol" ]]; then
   VOLUME_ZONE=`euca-describe-availability-zones | head -n1 | cut -f2`
   die_if_not_set VOLUME_ZONE "Failure to find zone for volume"

   VOLUME=`euca-create-volume -s 1 -z $VOLUME_ZONE | cut -f2`
   die_if_not_set VOLUME "Failure to create volume"

   # Test that volume has been created
   VOLUME=`euca-describe-volumes | cut -f2`
   die_if_not_set VOLUME "Failure to get volume"

   # Test volume has become available
   if ! timeout $ASSOCIATE_TIMEOUT sh -c "while ! euca-describe-volumes $VOLUME | grep -q available; do sleep 1; done"; then
       echo "volume didnt become available within $RUNNING_TIMEOUT seconds"
       exit 1
   fi

   # Attach volume to an instance
   euca-attach-volume -i $INSTANCE -d $ATTACH_DEVICE $VOLUME || \
       die "Failure attaching volume $VOLUME to $INSTANCE"
   if ! timeout $ACTIVE_TIMEOUT sh -c "while ! euca-describe-volumes $VOLUME | grep -q in-use; do sleep 1; done"; then
       echo "Could not attach $VOLUME to $INSTANCE"
       exit 1
   fi

   # Detach volume from an instance
   euca-detach-volume $VOLUME || \
       die "Failure detaching volume $VOLUME to $INSTANCE"
    if ! timeout $ACTIVE_TIMEOUT sh -c "while ! euca-describe-volumes $VOLUME | grep -q available; do sleep 1; done"; then
        echo "Could not detach $VOLUME to $INSTANCE"
        exit 1
    fi

    # Remove volume
    euca-delete-volume $VOLUME || \
        die "Failure to delete volume"
    if ! timeout $ACTIVE_TIMEOUT sh -c "while euca-describe-volumes | grep $VOLUME; do sleep 1; done"; then
       echo "Could not delete $VOLUME"
       exit 1
    fi
else
    echo "Volume Tests Skipped"
fi

# Allocate floating address
FLOATING_IP=`euca-allocate-address | cut -f2`
die_if_not_set FLOATING_IP "Failure allocating floating IP"

# Associate floating address
euca-associate-address -i $INSTANCE $FLOATING_IP || \
    die "Failure associating address $FLOATING_IP to $INSTANCE"

# Authorize pinging
euca-authorize -P icmp -s 0.0.0.0/0 -t -1:-1 $SECGROUP || \
    die "Failure authorizing rule in $SECGROUP"

# Test we can ping our floating ip within ASSOCIATE_TIMEOUT seconds
ping_check "$PUBLIC_NETWORK_NAME" $FLOATING_IP $ASSOCIATE_TIMEOUT

# Revoke pinging
euca-revoke -P icmp -s 0.0.0.0/0 -t -1:-1 $SECGROUP || \
    die "Failure revoking rule in $SECGROUP"

# Release floating address
euca-disassociate-address $FLOATING_IP || \
    die "Failure disassociating address $FLOATING_IP"

# Wait just a tick for everything above to complete so release doesn't fail
if ! timeout $ASSOCIATE_TIMEOUT sh -c "while euca-describe-addresses | grep $INSTANCE | grep -q $FLOATING_IP; do sleep 1; done"; then
    echo "Floating ip $FLOATING_IP not disassociated within $ASSOCIATE_TIMEOUT seconds"
    exit 1
fi

# Release floating address
euca-release-address $FLOATING_IP || \
    die "Failure releasing address $FLOATING_IP"

# Wait just a tick for everything above to complete so terminate doesn't fail
if ! timeout $ASSOCIATE_TIMEOUT sh -c "while euca-describe-addresses | grep -q $FLOATING_IP; do sleep 1; done"; then
    echo "Floating ip $FLOATING_IP not released within $ASSOCIATE_TIMEOUT seconds"
    exit 1
fi

# Terminate instance
euca-terminate-instances $INSTANCE || \
    die "Failure terminating instance $INSTANCE"

# Assure it has terminated within a reasonable time
if ! timeout $TERMINATE_TIMEOUT sh -c "while euca-describe-instances $INSTANCE | grep -q $INSTANCE; do sleep 1; done"; then
    echo "server didn't terminate within $TERMINATE_TIMEOUT seconds"
    exit 1
fi

# Delete group
euca-delete-group $SECGROUP || die "Failure deleting security group $SECGROUP"

set +o xtrace
echo "*********************************************************************"
echo "SUCCESS: End DevStack Exercise: $0"
echo "*********************************************************************"
