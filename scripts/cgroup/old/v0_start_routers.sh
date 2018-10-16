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


for i in `seq 2 $INSTANCES`;
do
  instance_name="${NAME}$i"
  veth_name="i2p$i"
  veth_addr="${IPPREFIX}$i"
  echo "[+] Startup of router instance $instance_name ($i of $INSTANCES)"
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


