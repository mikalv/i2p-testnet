#!/usr/bin/env bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

_NAME=$1
_NUM=$2
NAME=${_NAME:-"testnode"}
INSTANCES=${_NUM:-80}

IPPREFIX="192.168.24."
SUBNET="24"
GW_IP="${IPPREFIX}1"
GW_IP_SUBNET="${GW_IP}/${SUBNET}"
RESEED_URL="https://${IPPREFIX}1:8443/"

DATADIR="$DIR/data"
RESEED_DIR="$DATADIR/reseed"
NETDB_DIR="$DATADIR/reseed/netDb"
SIGNER=${SIGNER:-"meeh@mail.i2p"}
SIGNER_FNAME=${SIGNER_FNAME:-"meeh_at_mail.i2p"}


function setup_isolation_node() {
  ip netns del $1 &>/dev/null
  ip netns add $1
  ip link add peer-$2 type veth peer name $2 netns $1

  ovs-vsctl add-port i2pnet0 peer-$2
  # configure sandbox loopback
  ip netns exec $1 ip addr add 127.0.0.1/8 dev lo
  ip netns exec $1 ip link set lo up

  ip netns exec $1 ip addr add $3/$SUBNET dev $2
  ip netns exec $1 ip route add default via $GW_IP dev $2
  ip link set peer-$2 master i2pnet0
  ip link set peer-$2 up
  ip netns exec $1 ip link set $2 up
}



# Main sequence
ovs-vsctl del-br i2pnet0
ovs-vsctl add-br i2pnet0

# Ensure forward
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -o i2pnet0 -j MASQUERADE

# create a device pairs
#ip link add gateway0 type veth peer name peer-gateway0
#ip link set gateway0 up
ip addr add $GW_IP dev i2pnet0

# Setup reseed
mkdir -p $NETDB_DIR
cd $RESEED_DIR
i2p-tools keygen --tlsHost $GW_IP
i2p-tools keygen --signer $SIGNER
tmux new-session -d -s reseed i2p-tools reseed --numRi 20 --key $RESEED_DIR/${SIGNER_FNAME}.pem --netdb $RESEED_DIR/netDb --tlsHost ${GW_IP} --tlsCert ${GW_IP}.crt --tlsKey ${GW_IP}.pem --signer ${SIGNER_FNAME}
cd $DIR

tmux new-session -d -s routers top

for i in `seq 2 $INSTANCES`;
do
  instance_name="${NAME}$i"
  veth_name="i2p$i"
  veth_addr="${IPPREFIX}$i"
  echo "[+] Start setup of $instance_name ($i of $INSTANCES)"
  setup_isolation_node $instance_name $veth_name $veth_addr
  mkdir -p $DATADIR/$instance_name/certificates/reseed
  cp $RESEED_DIR/${SIGNER_FNAME}.crt $DATADIR/$instance_name/certificates/reseed/${SIGNER_FNAME}.crt
  tmux new-window -t routers -n $instance_name -d ip netns exec $instance_name i2pd --datadir=$DATADIR/$instance_name \
    --pidfile=$DATADIR/$instance_name/router.pid \
    --host="$veth_addr" \
    --port=4764 \
    --floodfill \
    --ipv4=1 \
    --ifname4 $veth_name \
    --log stdout \
    --reseed.urls=$RESEED_URL
  echo "[+] Spawned i2pd in tmux session 'routers' ($i of $INSTANCES)"
done




