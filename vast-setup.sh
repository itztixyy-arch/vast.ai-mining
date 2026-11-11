#!/usr/bin/env bash
# One-shot Pearl (PRL) GPU mining setup for a Vast.ai Linux instance, paid out in BTC via unMineable.
# Usage on the instance:  BTC_ADDRESS=bc1... bash vast-setup.sh   (re-run any time; it skips what is done)
#         stop:           pkill -f SRBMiner-MULTI ; pkill -f run-miner.sh
#         watch:          tail -f ~/miner/miner.log
set -euo pipefail

# Your BTC address is passed in, never stored in the repo:  BTC_ADDRESS=bc1... bash vast-setup.sh
BTC_ADDRESS="${BTC_ADDRESS:-${1:-}}"
case "$BTC_ADDRESS" in
  bc1*) ;;
  *) echo "Usage: BTC_ADDRESS=bc1... bash vast-setup.sh   (a bc1... Bitcoin address is required)"; exit 1 ;;
esac
WALLET="BTC:${BTC_ADDRESS}"
POOL="pearlpow.unmineable.com:3333"
VER="3.8.6"
URL="https://github.com/doktor83/SRBMiner-Multi/releases/download/${VER}/SRBMiner-Multi-${VER//./-}-Linux.tar.gz"
MD5="38128fa15afff3c488e53726aa251249"   # from the publisher's SRBMiner-Multi-3-8-6-Linux.tar.md5
DIR="$HOME/miner"
WORKER="vast$(hostname | tr -cd 'a-zA-Z0-9' | tail -c 8)"

command -v nvidia-smi >/dev/null || { echo "No NVIDIA GPU/driver visible on this instance."; exit 1; }
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader

mkdir -p "$DIR" && cd "$DIR"

if [ ! -x "$DIR/srb/SRBMiner-MULTI" ]; then
  for t in curl tar; do
    command -v $t >/dev/null || { apt-get update -qq && apt-get install -y -qq $t; }
  done
  curl -fL -o srb.tar.gz "$URL"
  echo "$MD5  srb.tar.gz" | md5sum -c - || { echo "Checksum mismatch, aborting."; rm -f srb.tar.gz; exit 1; }
  mkdir -p srb && tar -xzf srb.tar.gz -C srb --strip-components=1 && rm srb.tar.gz
fi

# Restart loop so a crash or pool drop does not leave the GPU idle.
cat > "$DIR/run-miner.sh" <<EOF
#!/usr/bin/env bash
cd "$DIR/srb"
while true; do
  ./SRBMiner-MULTI --algorithm-gpu pearlhash --pool $POOL --wallet $WALLET --worker $WORKER --password x
  echo "miner exited, restarting in 10s" >&2; sleep 10
done
EOF
chmod +x "$DIR/run-miner.sh"

pkill -f SRBMiner-MULTI 2>/dev/null || true
pkill -f run-miner.sh 2>/dev/null || true
nohup "$DIR/run-miner.sh" > "$DIR/miner.log" 2>&1 &

echo "Started. Worker name: $WORKER"
echo "Watch:  tail -f $DIR/miner.log   (look for hashrate and accepted shares)"
