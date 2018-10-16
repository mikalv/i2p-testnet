#!/usr/bin/env bash
_NAME=$1
_NUM=$2
NAME=${_NAME:-"testnode"}
INSTANCES=${_NUM:-20}

ip link delete gateway0


for i in `seq 2 $INSTANCES`;
do
  instance_name="${NAME}$i"
  veth_name="i2p$i"
  ip link delete $veth_name
  ip netns delete $instance_name
done

