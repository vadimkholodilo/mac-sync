#!/bin/bash
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PASS=0
FAIL=0
T=""

setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/root/bin" "$T/root/ansible" "$T/fake" "$T/home"
  cp "$REPO/bin/mac-sync" "$T/root/bin/mac-sync"
  cp "$REPO/ansible/requirements.yml" "$T/root/ansible/requirements.yml"
  : >"$T/root/ansible/playbook.yml"
  : >"$T/calls.log"
  printf 'source:\n  host: test-source\n' >"$T/root/config.yml"
  fake ssh 0
  fake ansible-playbook 0
  fake ansible-galaxy 0
  fake brew 0
  install_collection 13.3.0
}

fake() {
  printf '#!/bin/bash\necho "%s $*" >>"%s/calls.log"\nexit %s\n' "$1" "$T" "$2" >"$T/fake/$1"
  chmod +x "$T/fake/$1"
}

unfake() { rm -f "$T/fake/$1"; }

install_collection() {
  local d="$T/root/ansible/collections/ansible_collections/community/general"
  mkdir -p "$d"
  printf '{"collection_info": {"version": "%s"}}\n' "$1" >"$d/MANIFEST.json"
}

run_unattended() {
  HOME="$T/home" PATH="$T/fake:/usr/bin:/bin" MAC_SYNC_BREW_DIRS="" \
    /bin/bash "$T/root/bin/mac-sync" "$@" </dev/null >"$T/out" 2>&1
  RC=$?
}

run_interactive() {
  local answer="$1"
  shift
  # Delay the answer so it arrives after the prompt, and hold stdin open
  # afterwards so script does not inject an EOF (^D) in front of it.
  { sleep 1; printf '%s\n' "$answer"; sleep 2; } | HOME="$T/home" PATH="$T/fake:/usr/bin:/bin" MAC_SYNC_BREW_DIRS="" \
    script -q "$T/out" /bin/bash "$T/root/bin/mac-sync" "$@" >/dev/null 2>&1
  RC=$?
}

called() { grep -q -- "$1" "$T/calls.log"; }
log_has() { grep -q -- "$1" "$T/home/Library/Logs/mac-sync/mac-sync.log" 2>/dev/null; }

check() {
  local desc="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc (rc=$RC)"
    sed 's/^/    | /' "$T/out" 2>/dev/null | head -20
  fi
}
not() { ! "$@"; }
rc_is() { [ "$RC" = "$1" ]; }

teardown() { rm -rf "$T"; }


setup
run_unattended pull
check "happy path exits 0" rc_is 0
check "happy path runs ansible-playbook" called "ansible-playbook"
check "happy path installs nothing" not called "install"
check "lock released after run" test ! -e "$T/home/Library/Application Support/mac-sync/lock"
teardown

setup
run_unattended pull --check
check "--check passes --check --diff to ansible" called "ansible-playbook .*--check --diff"
teardown

setup
fake ssh 255
run_unattended pull
check "unreachable source exits 0" rc_is 0
check "unreachable source does not run ansible" not called "ansible-playbook"
check "unreachable source is logged" log_has "unreachable"
teardown

setup
run_unattended pull
check "ssh uses BatchMode and a timeout" called "ssh -o BatchMode=yes -o ConnectTimeout=5"
check "ssh records new host keys without prompting" called "StrictHostKeyChecking=accept-new"
teardown

setup
unfake ansible-playbook
unfake ansible-galaxy
run_unattended pull
check "missing ansible unattended exits 3" rc_is 3
check "missing ansible unattended installs nothing" not called "brew"
teardown

setup
unfake brew
run_unattended pull
check "brew absent but ansible present: no brew needed" rc_is 0
check "brew absent but ansible present: no install attempted" not called "install"
teardown

setup
install_collection 12.0.0
run_unattended pull
check "wrong collection version unattended exits 3" rc_is 3
check "wrong collection version unattended does not install" not called "ansible-galaxy"
teardown

setup
rm -rf "$T/root/ansible/collections"
run_interactive n pull
check "declining install exits 3" rc_is 3
check "declining install runs nothing" not called "ansible-galaxy"
teardown

setup
rm -rf "$T/root/ansible/collections"
run_interactive y pull
check "confirmed collection install runs galaxy" called "ansible-galaxy collection install"
teardown

setup
unfake ansible-playbook
unfake ansible-galaxy
run_interactive y pull
check "confirmed missing ansible uses brew install ansible" called "brew install ansible"
check "present brew is not reinstalled" not called "install.sh"
teardown

setup
rm -f "$T/root/config.yml"
run_unattended pull
check "missing config exits 2" rc_is 2
check "missing config does not touch ssh" not called "ssh"
teardown

setup
printf 'source:\n  host: -oProxyCommand=evil\n' >"$T/root/config.yml"
run_unattended pull
check "option-like host rejected with exit 2" rc_is 2
check "option-like host never reaches ssh" not called "ssh"
teardown

setup
printf 'source:\n  host: "quoted-host"  # comment\n' >"$T/root/config.yml"
run_unattended pull
check "quoted host with trailing comment parses" called "ssh .* -- quoted-host true"
teardown

setup
rm -f "$T/root/ansible/playbook.yml"
run_unattended pull
check "no playbook yet exits 0" rc_is 0
check "no playbook yet runs nothing" not called "ansible-playbook"
teardown

setup
mkdir -p "$T/home/Library/Application Support/mac-sync/lock"
(exec -a mac-sync sleep 30) &
HOLDER=$!
printf '%s\n' "$HOLDER" >"$T/home/Library/Application Support/mac-sync/lock/pid"
run_unattended pull
kill "$HOLDER" 2>/dev/null
check "live lock exits 0" rc_is 0
check "live lock skips the run" not called "ssh"
teardown

setup
mkdir -p "$T/home/Library/Application Support/mac-sync/lock"
echo 99999999 >"$T/home/Library/Application Support/mac-sync/lock/pid"
run_unattended pull
check "stale lock is cleared and run proceeds" called "ansible-playbook"
teardown

setup
run_unattended bogus
check "unknown command exits 64" rc_is 64
teardown

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" = 0 ]
