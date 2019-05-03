#!/bin/bash

# Sets up inbound/outbound dummynet in pf firewall for thorttling network conencts on particular ports.
# Can be modified for use with IPs or hostnames instead ports if desired.
# gtihub.com/tylertreat/comcast is a much nicer tool but I couldn't get it to work due
# to shell issues and more - it seemed to only setup inbound rules in pf which don't affect outbound
# TCP connections.

SCRIPT="./$(basename $0)"
CMD=$1

# Number of ports to apply shaping to
NUM=1

# dnctl in/out pipe configurations. For possibilities see: https://www.manpagez.com/man/8/dnctl/
CONFIG_IN=
CONFIG_OUT=

# Port the server communicates on (could be made configurable and/or IP/host based)
SERVER_PORT=4004

# If the client ports aren't taken from the currently connected ports then it can be specified here
CLIENT_PORT=0

# Supress noisy ALTQ nonsense
PFQUIET="grep -v 'ALTQ\|pf.conf\|flushing of rules\|present in the main ruleset\|^$'"

PORTS=()

usage() {
  echo -n "$SCRIPT [COMMAND] [OPTIONS...]
 Commands (optional):
  stop              Clear rules and disable firewall
  ports             Show active connected ports to specified server port (4004 default)

 Options:
  -i, --in          Inbound pipe configuration * (default: delay 40ms)
  -o, --out         Outbound pipe configuration * (default: delay 40ms)
  -c, --config      Set both pipe configurations * (default: delay 40ms)
  -n, --num-ports   Max number of active ports to filter if no client port specified (default: 1)
  -s, --server-port Server port (default: 4004)
  -p, --client-port Client port if not based on current active ports

 * For pipe configuration options see: https://www.manpagez.com/man/8/dnctl/

 Examples:
 # Default: 40ms delay on 1 random port connected to 4004
  $SCRIPT
 # 20ms delay in+out on 1 random port conencted to 4004
  $SCRIPT -c \"delay 20ms\"
 # 40ms delay in+out on ALL active ports connected to 4004
  $SCRIPT -n 0
 # List active ports connected to port 3000
  $SCRIPT ports -s 3000
 # 40ms delay in+out on port 8080 connected to 4004
  $SCRIPT -p 8080
"
}

stop() {
  if [[ $(sudo pfctl -sa 2>&1 | grep -i -c enabled) -ne 0 ]]; then
    # Teardown Pipe
    sudo dnctl -q flush

    # Reset pf
    sudo pfctl -f /etc/pf.conf 2> >(eval "$PFQUIET")
    sudo pfctl -d 2>/dev/null

    echo "Packet shaping stopped."
  fi
}

# Retreive the ports currently connected to the node server port
connected_ports() {
  PORTS=($(lsof -i TCP:$SERVER_PORT -a | sed -E -n 's/^.*\:([0-9]+) .*$/\1/p'))
  if [[ -n "$1" ]]; then
    echo "Active ports connected to $SERVER_PORT:"
    for p in "${PORTS[@]}"; do
      echo " $p"
    done
  fi
}

# Add rules that send inbound to pipe 1 and outbound to pipe 2
dummyport() {
  {
    echo "dummynet in quick proto tcp from any port $1 to any port $SERVER_PORT pipe 1"
    echo "dummynet out quick proto tcp from any port $SERVER_PORT to any port $1 pipe 2"
  } | sudo pfctl -a mop -f - 2> >(eval "$PFQUIET")
  echo "Rules applied to port: $1"
}

while [[ -n "$1" ]]; do
  case $1 in
    -i | --in )
      shift
      CONFIG_IN=$1
      ;;
    -o | --out )
      shift
      CONFIG_OUT=$1
      ;;
    -c | --config )
      shift
      CONFIG_IN=$1
      CONFIG_OUT=$1
      ;;
    -s | --server-port )
      shift
      SERVER_PORT=$1
      ;;
    -p | --client-port )
      shift
      CLIENT_PORT=$1
      NUM=1
      ;;
    -n | --num-ports )
      shift
      NUM=$1
      ;;
    -h | --help )
      usage
      exit
      ;;
  esac
  shift
done

if [[ "$CMD" == 'stop' ]]; then
  stop
  exit
elif [[ "$CMD" == 'ports' ]]; then
  connected_ports print
  exit
fi

if [[ -z "$CONFIG_IN" ]]; then
  CONFIG_IN="delay 40ms"
fi
if [[ -z "$CONFIG_OUT" ]]; then
  CONFIG_OUT="delay 40ms"
fi

# If a client port is set then we will just use that,
# otherwise we need to do some checks to ensure there are active
# ports to shape.

if [[ CLIENT_PORT -ne 0 ]]; then
  PORTS=($CLIENT_PORT)
  NUM=1
elif [[ NUM -lt 0 ]]; then
  echo "Invalid number of ports requested: $NUM"
  exit 1
else
  connected_ports
  if [[ ${#PORTS[@]} -eq 0 ]]; then
    echo "There are currently no active ports connected to port $SERVER_PORT."
    exit 1
  elif [[ NUM -eq 0 ]]; then
    NUM=${#PORTS[@]}
  fi
fi

# Enable firewall if necessary
sudo pfctl -e 2>/dev/null

# Add rule set
(cat /etc/pf.conf && echo "dummynet-anchor \"mop\"" && echo "anchor \"mop\"") | sudo pfctl -f - 2> >(eval "$PFQUIET")

# Setup dummy net
for port in "${PORTS[@]:0:NUM} "; do
  dummyport $port
done

# Create inbound pipe
if [[ "$CONFIG_IN" != "0" ]]; then
  sudo dnctl pipe 1 config $CONFIG_IN
  echo "Applied in config: $CONFIG_IN"
else
  sudo dnctl pipe 1 config
fi
# Create outbound pipe
if [[ "$CONFIG_OUT" != "0" ]]; then
  sudo dnctl pipe 2 config $CONFIG_OUT
  echo "Applied out config: $CONFIG_OUT"
else
  sudo dnctl pipe 2 config
fi

# Wait for input
read -p "Press any key to stop throttling traffic"

stop


