#!/usr/bin/env bash
# Pearl (PRL) GPU mining on a rented Linux NVIDIA box, paid out in BTC via unMineable.
# Run:   curl -fsSL https://raw.githubusercontent.com/itztixyy-arch/vast.ai-mining/main/vast-setup.sh | BTC_ADDRESS=bc1... bash
# It installs two miners, starts the first one that really hashes, and prints WORKING or NOT WORKING.
# Re-run any time. Stop: pkill -f run-miner.sh; pkill -f SRBMiner-MULTI; pkill -f bzminer
set -u

POOL_HOST="pearlpow.unmineable.com"; POOL_PORT=3333
DIR="$HOME/miner"
SRB_URL="https://github.com/doktor83/SRBMiner-Multi/releases/download/3.8.6/SRBMiner-Multi-3-8-6-Linux.tar.gz"
SRB_MD5="38128fa15afff3c488e53726aa251249"
BZ_URL="https://github.com/bzminer/bzminer/releases/download/v100.70/bzminer_v100.70_linux.tar.gz"
BZ_SHA256="8e99e9aeb4b16356c72ab28a84e5ef2cee72e050b543717d9ad6654abac859e0"
WAIT_SECS=120
SELF_URL="https://raw.githubusercontent.com/itztixyy-arch/vast.ai-mining/main/vast-setup.sh"

say()  { printf '%s\n' "$*"; }
fail() { say ""; say "NOT WORKING: $*"; exit 1; }

need_tool() {  # install a missing tool, with sudo if we are not root
  command -v "$1" >/dev/null && return 0
  local sudo=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && sudo="sudo -n"
  $sudo apt-get update -qq >/dev/null 2>&1; $sudo apt-get install -y -qq "$1" >/dev/null 2>&1
  command -v "$1" >/dev/null || fail "need '$1' and could not install it (no root/sudo)."
}

fetch() {  # fetch NAME URL CHECKTYPE CHECKSUM  -> extracts into $DIR/NAME
  local name=$1 url=$2 kind=$3 sum=$4 f="$DIR/$1.tar.gz"
  [ -n "$(find "$DIR/$name" -type f \( -name SRBMiner-MULTI -o -name bzminer \) 2>/dev/null | head -1)" ] && return 0
  say "Downloading $name ..."
  curl -fsSL -o "$f" "$url" || { say "  download of $name failed"; return 1; }
  if [ "$kind" = md5 ]; then echo "$sum  $f" | md5sum -c - >/dev/null 2>&1 || { say "  $name checksum mismatch, discarded"; rm -f "$f"; return 1; }
  else echo "$sum  $f" | sha256sum -c - >/dev/null 2>&1 || { say "  $name checksum mismatch, discarded"; rm -f "$f"; return 1; }; fi
  mkdir -p "$DIR/$name" && tar -xzf "$f" -C "$DIR/$name" && rm -f "$f"
}

# try_miner NAME LOGFILE OK_REGEX -- command...   starts it, waits for real hashing. 0 = hashing.
try_miner() {
  local name=$1 log=$2 ok=$3; shift 4
  say "Trying $name ..."
  : > "$log"; nohup "$@" > "$log" 2>&1 & local pid=$!
  local t=0
  while [ $t -lt $WAIT_SECS ]; do
    sleep 5; t=$((t+5))
    kill -0 $pid 2>/dev/null || { say "  $name exited after ${t}s: $(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -iE 'naughty|error|unavailable|fail' | head -1)"; return 1; }
    if sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -Eq "$ok"; then return 0; fi
  done
  say "  $name ran ${WAIT_SECS}s but never showed a hashrate"; kill $pid 2>/dev/null; return 1
}

# Watchdog: every 5 min, if the miner is gone or its log went quiet, re-run this setup (which also swaps miners).
# Autostart: cron @reboot restarts the watchdog loop after a reboot. For a container restart on Vast, put the
# one-line setup command in the template's "On-start script" box.
write_helpers() {
  cat > "$DIR/watch.sh" <<'W'
#!/usr/bin/env bash
# Live view of the miner. "auto" (used at login) only attaches if the miner session exists.
if tmux has-session -t miner 2>/dev/null; then tmux attach -t miner
elif [ "${1:-}" != auto ]; then tail -n 30 -f "$HOME/miner/miner.log"; fi
W
  cat > "$DIR/stop.sh" <<'S'
#!/usr/bin/env bash
# Stops the miner AND its watchdog, so nothing restarts it.
crontab -l 2>/dev/null | grep -v 'miner/watchdog.sh' | crontab - 2>/dev/null
pkill -f miner-watch-loop; pkill -f run-miner.sh; tmux kill-session -t miner 2>/dev/null
pkill -f SRBMiner-MULTI; pkill -f bzminer
echo "Miner and watchdog stopped."
S
  cat > "$DIR/loop.sh" <<'L'
#!/usr/bin/env bash
# Starts the 5-minute watchdog loop if it is not already running.
pgrep -f miner-watch-loop >/dev/null && exit 0
nohup bash -c 'while true; do sleep 300; bash "$HOME/miner/watchdog.sh"; done' miner-watch-loop >/dev/null 2>&1 &
L
  chmod +x "$DIR/watch.sh" "$DIR/stop.sh" "$DIR/loop.sh"
}

install_autostart() {
  write_helpers
  # Without root, cron cannot run. Fallback: every login revives the watchdog loop and shows the live miner.
  grep -q 'miner/loop.sh' "$HOME/.bashrc" 2>/dev/null || echo '[ -n "$PS1" ] && { bash "$HOME/miner/loop.sh"; [ -z "$TMUX" ] && bash "$HOME/miner/watch.sh" auto; }   # miner autostart' >> "$HOME/.bashrc"
  cat > "$DIR/watchdog.sh" <<'WD'
#!/usr/bin/env bash
D="$HOME/miner"
healthy() { pgrep -f run-miner.sh >/dev/null && pgrep -f "SRBMiner-MULTI|bzminer" >/dev/null && [ -n "$(find "$D/miner.log" -mmin -5 2>/dev/null)" ]; }
healthy && exit 0
sleep 20; healthy && exit 0
command -v flock >/dev/null && { exec 9>"$D/.lock"; flock -n 9 || exit 0; }
echo "$(date) miner unhealthy, re-running setup" >> "$D/watchdog.log"
BTC_ADDRESS="$(cat "$D/.address")" bash "$D/vast-setup.sh" >> "$D/watchdog.log" 2>&1
WD
  chmod +x "$DIR/watchdog.sh"
  bash "$DIR/loop.sh"
  AUTOSTART="watchdog loop + login revive (cron not available)"
  local sudo=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && sudo="sudo -n"
  command -v crontab >/dev/null || $sudo apt-get install -y -qq cron >/dev/null 2>&1
  if command -v crontab >/dev/null; then
    ( crontab -l 2>/dev/null | grep -v 'miner/watchdog.sh'
      echo "@reboot sleep 30; bash $DIR/loop.sh"
      echo "*/5 * * * * bash $DIR/watchdog.sh" ) | crontab - 2>/dev/null
    $sudo service cron start >/dev/null 2>&1
    # Only claim cron if its daemon is really running (it cannot start without root).
    pgrep -x cron >/dev/null && AUTOSTART="cron @reboot + 5-min watchdog"
  fi
}

main() {
  BTC_ADDRESS="${BTC_ADDRESS:-${1:-}}"
  case "$BTC_ADDRESS" in bc1*) ;; *) fail "give your address:  BTC_ADDRESS=bc1... bash vast-setup.sh" ;; esac
  local wallet="BTC:${BTC_ADDRESS}" worker="v$(hostname | tr -cd 'a-zA-Z0-9' | tail -c 8)"

  command -v nvidia-smi >/dev/null || fail "no NVIDIA driver/GPU visible on this machine."
  say "GPU: $(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader | head -2 | tr '\n' ';')"
  mkdir -p "$DIR"; need_tool curl; need_tool tar
  command -v tmux >/dev/null || { s=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && s="sudo -n"; $s apt-get install -y -qq tmux >/dev/null 2>&1; }
  printf '%s' "$BTC_ADDRESS" > "$DIR/.address"; chmod 600 "$DIR/.address"   # so the watchdog can re-run setup
  curl -fsSL -o "$DIR/vast-setup.sh.new" "$SELF_URL" && mv "$DIR/vast-setup.sh.new" "$DIR/vast-setup.sh"
  curl -fsS -m 10 -o /dev/null "https://$POOL_HOST" 2>/dev/null || getent hosts "$POOL_HOST" >/dev/null || fail "cannot reach $POOL_HOST (blocked network or DNS)."

  pkill -f run-miner.sh 2>/dev/null; pkill -f SRBMiner-MULTI 2>/dev/null; pkill -f bzminer 2>/dev/null; sleep 1

  local srb bz used="" cmd
  fetch srb "$SRB_URL" md5 "$SRB_MD5" && srb=$(find "$DIR/srb" -type f -name SRBMiner-MULTI | head -1) && chmod +x "$srb"
  fetch bz "$BZ_URL" sha256 "$BZ_SHA256" && bz=$(find "$DIR/bz" -type f -name bzminer | head -1) && chmod +x "$bz"
  [ -n "${srb:-}${bz:-}" ] || fail "could not download any miner (GitHub unreachable?)."

  local srb_cmd="$srb --algorithm-gpu pearlhash --pool $POOL_HOST:$POOL_PORT --wallet $wallet --worker $worker --password x"
  local bz_cmd="$bz -a pearl -p stratum+tcp://$POOL_HOST:$POOL_PORT -w $wallet --worker $worker --pass x --nvidia -o log"

  if [ -n "${srb:-}" ] && try_miner SRBMiner "$DIR/miner.log" '[1-9][0-9.]* [TGM]H/s' -- $srb_cmd; then used=SRBMiner; cmd=$srb_cmd
  else
    pkill -f SRBMiner-MULTI 2>/dev/null
    if [ -n "${bz:-}" ] && try_miner BzMiner "$DIR/miner.log" 'hashrate [1-9][0-9.]*|[1-9][0-9.]* ?[TGMP][Hh]/?s?' -- $bz_cmd; then used=BzMiner; cmd=$bz_cmd; fi
  fi
  [ -n "$used" ] || fail "no miner could hash on this GPU. Last log: $(tail -n 3 "$DIR/miner.log" | tr '\n' ' ')"

  # Hand over to a restart loop so a crash or pool drop does not leave the GPU idle.
  pkill -f SRBMiner-MULTI 2>/dev/null; pkill -f bzminer 2>/dev/null; sleep 2
  printf '#!/usr/bin/env bash\nwhile true; do %s; echo "miner exited, restarting in 10s" >&2; sleep 10; done\n' "$cmd" > "$DIR/run-miner.sh"
  chmod +x "$DIR/run-miner.sh"; : > "$DIR/miner.log"
  # Run inside tmux so you can look at the live screen any time (and the watchdog restarts it in there too).
  tmux kill-session -t miner 2>/dev/null
  if command -v tmux >/dev/null; then tmux new-session -d -s miner "bash $DIR/run-miner.sh 2>&1 | tee -a $DIR/miner.log"
  else nohup "$DIR/run-miner.sh" > "$DIR/miner.log" 2>&1 & fi
  sleep 5; pgrep -f "SRBMiner-MULTI|bzminer" >/dev/null || fail "$used started but stopped again; see $DIR/miner.log"

  AUTOSTART="none"; [ -s "$DIR/vast-setup.sh" ] && install_autostart
  say ""; say "WORKING: $used is mining Pearl as worker $worker -> BTC to your address."
  say "Auto-restart: $AUTOSTART"
  say "Watch it live any time:  bash ~/miner/watch.sh     (leave the view with Ctrl+B then D; the miner keeps running)"
  say "Stop everything:  bash ~/miner/stop.sh"
  say "Check later:  tail -n 20 ~/miner/miner.log   (accepted shares take hours at this difficulty)"
}

[[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
