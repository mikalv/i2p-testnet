#!/bin/bash -x
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

DATADIR=${DATADIR:-"$DIR/data"}
PIDDIR=${PIDDIR:-"$DATADIR/pids/"}
LOGDIR=${LOGDIR:-"$DATADIR/logs/"}

RESEEDSERVER=${RESEEDSERVER:-"https://192.168.24.1:8443/"}
RESEEDSERVER_IP=${RESEEDSERVER_IP:-"192.168.24.1"}
RESEED_DIR="$DATADIR/reseed"
NETDB_DIR="$DATADIR/reseed/netDb"
SIGNER=${SIGNER:-"meeh@mail.i2p"}
SIGNER_FNAME=${SIGNER_FNAME:-"meeh_at_mail.i2p"}

mkdir -p $DATADIR $PIDDIR $LOGDIR

# Tmux session for all routers
tmux new-session -d -s routers top

I2PDWRAPPER=$(cat <<EOF
#!/usr/bin/env bash\n
ip netns exec \$2 i2pd \
  --datadir=$DATADIR/testnode\$1 \
  --log stdout \
  --floodfill \
  --ipv4=1 \
  --host=\$3 \
  --ifname4=veth0 \
  --pidfile=$PIDDIR/router\$1.pid \
  --port=4764 \
  --reseed.urls=$RESEEDSERVER | tee -a $LOGDIR/router\$1.log >> $LOGDIR/all-routers.log &
EOF
)


for i in `seq 1 128`; do
  mkdir -p $DATADIR/testnode$i/certificates/reseed
  cp $DATADIR/reseed/${SIGNER_FNAME}.crt $DATADIR/testnode$i/certificates/reseed/
  echo -e $I2PDWRAPPER > $DATADIR/testnode$i/i2pdwrapper.sh
done

#echo $I2PDWRAPPER
#exit 0


haderror=""

if [ "`id -r -u`" != "0" ]
then
  echo "Must be root"
  echo ""
  haderror="Y"
fi

if [ "$haderror" -o $# -lt 1 ]
then
  echo "Usage: sudo ./i2ptestnet.sh [-c] setup-file"
  exit 1
fi

if [ "$1" = "-c" ]
then
  cleanonly=Y
  shift
else
  cleanonly=
fi

setup="$1"
shift
setupbase="$(basename $setup)"
errline=""
error=""

if ! MYTMP="`mktemp -d -t i2ptestnet-XXXXXX`"
then
            echo >&2
            echo >&2
            echo >&2 "Cannot create temporary directory."
            echo >&2
            exit 1
fi

myexit() {
  status=$?
  if [ "$error" != "" ]
  then
    echo "$setupbase: line $errline: $error"
  fi
  rm -rf $MYTMP
  exit $status
}

trap myexit INT
trap myexit HUP
trap myexit 0

CURDIR=`pwd`/
export CURDIR

set -e

mkdir $MYTMP/setup
(echo "cd $CURDIR"; sed = "$setup" | sed -e 'N;s/\n/\t/' -e 's/^/lineno=/' -e '/exec/s/[<>|&]/\\&/g' -e '/i2preseed/s/[<>|&]/\\&/g' -e '/i2pdnode/s/[<>|&]/\\&/g') > $MYTMP/setup/$setupbase

mkdir $MYTMP/ns
mkdir $MYTMP/runtime-lines

current_name=

create_namespace() {
  errline=$lineno
  local type="$1"
  current_name="$2"
  NSTMP=$MYTMP/ns/$current_name
  if [ -d $NSTMP ]
  then
    error="$current_name: $(cat $NSTMP/type) already defined"
    return 1
  fi
  mkdir $NSTMP
  mkdir $NSTMP/devices
  mkdir $NSTMP/devicepairs
  echo $type > $NSTMP/type
  echo 0 > $NSTMP/forward
  > $NSTMP/routes
  > $NSTMP/devlist
  > $NSTMP/pairlist
  > $NSTMP/bridgelist
  echo $current_name >> $MYTMP/nslist
  echo $errline > $MYTMP/runtime-lines/$current_name
}

host() {
  errline=$lineno
  create_namespace host "$1"
}

switch() {
  errline=$lineno
  create_namespace switch "$1"
}

dev() {
  errline=$lineno
  device="$1"
  shift

  if [ ! "$current_name" ]
  then
    error="cannot define dev outside of a host or switch"
    return 1
  fi

  if [ -f $NSTMP/devices/$device ]
  then
    error="$current_name/$device: already defined"
    return 1
  fi

  local otherns=
  local otherdev=
  case $1 in
    */[a-zA-Z@]*)
      otherns=$(echo $1 | cut -f1 -d/)
      otherdev=$(echo $1 | cut -f2 -d/)
      shift
      if [ -f $MYTMP/ns/$otherns/devicepairs/$otherdev ]
      then
        error="$otherns/$otherdev: already has paired device"
        return 1
      fi
    ;;
  esac

  local type="$(cat $NSTMP/type)"
  if [ "$*" != "" -a "$type" = "switch" ]
  then
    error="device in switch may not specify an IP address"
    return 1
  fi


  f=$NSTMP/devices/${device%@*}
  > $f
  for ip in "$@"
  do
    case $ip in
      */*)
       echo "$ip" >> $f
      ;;
      *)
       error="IP address should be expressed as ip/mask"
       return 1
      ;;
    esac
  done

  if [ "$otherdev" ]
  then
    echo "$current_name ${device%@*}" > $MYTMP/ns/$otherns/devicepairs/${otherdev%@*}
    echo "n/a n/a" > $NSTMP/devicepairs/${device%@*}
    echo "$otherns ${otherdev%@*}" >> $NSTMP/pairlist
    echo $errline > $MYTMP/runtime-lines/$otherns-pair-${otherdev%@*}
  fi

  echo ${device%@*} >> $NSTMP/devlist
  echo $errline > $MYTMP/runtime-lines/$current_name-dev-${device%@*}
  return 0
}

route() {
  errline=$lineno
  if [ ! "$current_name" ]
  then
    error="can only specify route in a host"
    return 1
  fi

  local type="$(cat $NSTMP/type)"
  if [ "$type" = "switch" ]
  then
    error="can only specify route in a host"
    return 1
  fi

  echo "$*" >> $NSTMP/routes
  echo $errline >> $MYTMP/runtime-lines/$current_name-routes
  return 0
}

bridgedev() {
  errline=$lineno
  device="$1"
  shift

  if [ ! "$current_name" ]
  then
    error="can only specify bridgedev in a host"
    return 1
  fi

  local type="$(cat $NSTMP/type)"
  if [ "$type" = "switch" ]
  then
    error="can only specify bridgedev in a host"
    return 1
  fi

  if [ -f $NSTMP/devices/${device%@*} ]
  then
    error="$current_name/${device%@*}: already defined"
    return 1
  fi

  ipf=$NSTMP/devices/${device%@*}
  devf=$ipf-bridged
  > $ipf
  > $devf
  for ipordev in "$@"
  do
    case $ipordev in
      */*)
       echo "$ipordev" >> $ipf
      ;;
      *)
       echo "$ipordev" >> $devf
      ;;
    esac
  done

  echo ${device%@*} >> $NSTMP/bridgelist
  echo $errline > $MYTMP/runtime-lines/$current_name-dev-${device%@*}
  return 0
}

exec() {
  errline=$lineno
  if [ ! "$current_name" ]
  then
    error="can only specify exec in a host or switch"
    return 1
  fi

  echo "$*" >> $NSTMP/exec
  echo $errline >> $MYTMP/runtime-lines/$current_name-exec
  return 0
}

i2pdnode() {
  errline=$lineno
  if [ ! "$current_name" ]
  then
    error="can only specify i2pdnode in a host or switch"
    return 1
  fi

  echo -e "$*" >> $NSTMP/i2pdnodeid
  echo $errline >> $MYTMP/runtime-lines/$current_name-i2pdnodeid
  return 0
}


i2preseed() {
  errline=$lineno
  if [ ! "$current_name" ]
  then
    error="can only specify i2preseed in a host or switch"
    return 1
  fi

  echo -e "$*" >> $NSTMP/i2preseed
  echo $errline >> $MYTMP/runtime-lines/$current_name-i2preseed
  return 0
}

cd $MYTMP/setup
. $setupbase
errline=""
cd $CURDIR

exists_ns() {
  if [ "$(ip netns list | grep "^$1\$")" ]
  then
    return 0
  else
    return 1
  fi
}

dev_in_ns() {
  ip netns exec $1 ip link list | grep "^[0-9]" | cut -d: -f2 | tr -d ' '
}

get_pids() {
  # Not in all versions:
  #   ip netns pids $1
  find -L /proc/[0-9]*/ns -maxdepth 1 -samefile /var/run/netns/$1 2>/dev/null | cut -f3 -d/
}

shutdown_ns() {
  for i in $(dev_in_ns $1)
  do
    ip netns exec $1 ip link set ${i%@*} down
  done
  pids=$(get_pids $1)
  if [ "$pids" ]; then kill $pids; sleep 1; fi
  pids=$(get_pids $1)
  if [ "$pids" ]; then kill -9 $pids; fi
}

startup_ns() {
  for i in $(dev_in_ns $1)
  do
    ip netns exec $1 ip link set ${i%@*} up
  done
}

while read ns
do
  while read dev
  do
    read errline < $MYTMP/runtime-lines/$ns-dev-$dev
    if [ ! -f $MYTMP/ns/$ns/devicepairs/$dev ]
    then
      error="$ns/$dev has no paired device"
      exit 1
    fi
  done < $MYTMP/ns/$ns/devlist

  while read otherns otherdev
  do
    read errline < $MYTMP/runtime-lines/$otherns-pair-$otherdev
    if [ ! -f $MYTMP/ns/$otherns/devices/$otherdev ]
    then
      error="$otherns/$otherdev not defined to be paired with"
      exit 1
    fi
  done < $MYTMP/ns/$ns/pairlist
done < $MYTMP/nslist

while read ns
do
  read errline < $MYTMP/runtime-lines/$ns
  error="shutting down namespace: $ns"
  exists_ns $ns && shutdown_ns $ns
done < $MYTMP/nslist

while read ns
do
  read errline < $MYTMP/runtime-lines/$ns
  error="deleting namespace"
  exists_ns $ns && ip netns del $ns
done < $MYTMP/nslist

if [ "$cleanonly" ]
then
  error=""
  exit 0
fi

while read ns
do
  read errline < $MYTMP/runtime-lines/$ns
  error="adding namespace"
  type="$(cat $MYTMP/ns/$ns/type)"
  ip netns add $ns
  if [ "$type" = "switch" ]
  then
    error="adding bridge to switch namespace"
    ip netns exec $ns brctl addbr switch
  fi
done < $MYTMP/nslist

while read ns
do
  type="$(cat $MYTMP/ns/$ns/type)"
  while read dev
  do
    read errline < $MYTMP/runtime-lines/$ns-dev-${dev%@*}
    read ons odev < $MYTMP/ns/$ns/devicepairs/${dev%@*}
    if [ "$ons" != "n/a" ]
    then
      error="adding virtual ethernet to $type namespace"
      ip link add ${dev%@*} netns $ns type veth peer netns $ons name ${odev%@*}
    else
      : # gets set up from the other end
    fi
    if [ "$type" = "switch" ]
    then
      error="adding virtual ethernet to bridge"
      ip netns exec $ns brctl addif switch ${dev%@*}
    fi
    while read ip
    do
      error="adding ip address to virtual ethernet"
      ip netns exec $ns ip addr add $ip dev ${dev%@*}
    done < $MYTMP/ns/$ns/devices/${dev%@*}
  done < $MYTMP/ns/$ns/devlist

  while read bridge
  do
    read errline < $MYTMP/runtime-lines/$ns-dev-$bridge
    error="adding bridge to host namespace"
    ip netns exec $ns brctl addbr $bridge
    while read dev
    do
      error="adding virtual interface to bridge"
      ip netns exec $ns brctl addif $bridge ${dev%@*}
    done < $MYTMP/ns/$ns/devices/$bridge-bridged
    while read ip
    do
      error="adding ip to virtual interface"
      ip netns exec $ns ip addr add $ip dev $bridge
    done < $MYTMP/ns/$ns/devices/$bridge
  done < $MYTMP/ns/$ns/bridgelist
done < $MYTMP/nslist

while read ns
do
  read errline < $MYTMP/runtime-lines/$ns
  error="starting namespace"
  startup_ns $ns

  while read route
  do
    errline=$(tr "\n" "/" < $MYTMP/runtime-lines/$ns-routes | sed -e s:/$::)
    error="adding route to $ns"
    ip netns exec $ns ip route add $route
  done < $MYTMP/ns/$ns/routes

  if [ -f $MYTMP/ns/$ns/exec ]
  then
    errline=$(tr "\n" "/" < $MYTMP/runtime-lines/$ns-exec | sed -e s:/$::)
    error="running exec for $ns"
    ip netns exec $ns sh -e $MYTMP/ns/$ns/exec
  fi

  if [ -f $MYTMP/ns/$ns/i2pdnodeid ]
  then
    errline=$(tr "\n" "/" < $MYTMP/runtime-lines/$ns-i2pdnodeid | sed -e s:/$::)
    error="running i2pdnode for $ns"
    routerId="`cat $MYTMP/ns/$ns/i2pdnodeid`"
    #echo "Router id to handle is $routerId"
    routerAddress="`ip netns exec $ns ip -o addr show veth0 | grep -v inet6 | awk '{ print $4 }' | sed 's#/24##'`"
    ip netns exec $ns bash $DATADIR/testnode$routerId/i2pdwrapper.sh $routerId $ns $routerAddress
    #i2pd \
    #  --datadir=$DATADIR/testnode$routerId \
    #  --log file \
    #  --daemon \
    #  --floodfill \
    #  --ipv4=1 \
    #  --host=$routerAddress \
    #  --ifname=veth0 \
    #  --logfile=$LOGDIR/router$routerId.log \
    #  --pidfile=$PIDDIR/router$routerId.pid \
    #  --port=4764 \
    #  --reseed.urls=$RESEEDSERVER || {
    #    echo "Can't start i2pd, total fucking error!"
    #    exit 1
    #  }
  fi

  if [ -f $MYTMP/ns/$ns/i2preseed ]
  then
    errline=$(tr "\n" "/" < $MYTMP/runtime-lines/$ns-i2preseed | sed -e s:/$::)
    error="running i2preseed for $ns"
    cd $RESEED_DIR
    #i2p-tools keygen --tlsHost $RESEEDSERVER_IP
    #i2p-tools keygen --signer $SIGNER
    echo "Setting up reseed"
    ip netns exec $ns i2p-tools reseed \
        --numRi 20 \
        --key $RESEED_DIR/${SIGNER_FNAME}.pem \
        --netdb $RESEED_DIR/netDb \
        --tlsHost $RESEED_DIR/${RESEEDSERVER_IP} \
        --tlsCert $RESEED_DIR/${RESEEDSERVER_IP}.crt \
        --tlsKey $RESEED_DIR/${RESEEDSERVER_IP}.pem \
        --signer $RESEED_DIR/${SIGNER_FNAME} &
    cd -
  fi
done < $MYTMP/nslist
error=""

while read ns
do
  echo "---------------------- $ns --------------------"
  ip netns exec $ns ip addr show
  ip netns exec $ns ip route show
  ip netns exec $ns brctl show
  echo ""
done < $MYTMP/nslist

exit 0