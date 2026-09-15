#!/usr/bin/env bash
# tests/run.sh — checks for the privileged install path.
#
# The interesting code is the staging step inside install-system.sh: root reads
# the plugin folder through descriptors it opened with O_NOFOLLOW, hashes what
# it actually got, and refuses to install anything whose bytes are not the ones
# recorded at release time. That step needs no privilege of its own, so the
# tests extract it and run it unprivileged against fixture trees — including the
# ones an attacker would build.
#
#   tests/run.sh          run everything
#   tests/run.sh -v       also print each check as it passes

set -uo pipefail
IFS=$'\n\t'
export LC_ALL=C

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
VERBOSE=0
[[ ${1:-} == -v ]] && VERBOSE=1

pass=0 fail=0
ok()   { pass=$((pass+1)); (( VERBOSE )) && printf '  ok   %s\n' "$1"; return 0; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [[ -n ${2:-} ]] && printf '       %s\n' "$2"; return 0; }
check(){ if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3" "expected [$2], got [$1]"; fi; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-vpn-tests.XXXXXX")
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf -- "$TMP"' EXIT

# ---------------------------------------------------------------- the stager
# Pull the embedded Python out of install-system.sh so the tests exercise the
# very bytes that ship, not a copy that could drift.
STAGER="$TMP/stager.py"
sed -n "/<<'PYSTAGE'/,/^PYSTAGE\$/p" "$REPO/install-system.sh" \
  | sed '1d;$d' > "$STAGER"
[[ -s $STAGER ]] || { echo "could not extract the stager from install-system.sh" >&2; exit 1; }

# The payload list and its digests, read from install-system.sh the same way.
mapfile -t RELS < <(
  sed -n '/^PAYLOAD=(/,/^)/p' "$REPO/install-system.sh" \
    | sed -n 's/^[[:space:]]*"\([^:"]*\):.*/\1/p'
)
mapfile -t SUMS < <(
  sed -n '/^PAYLOAD_SHA256=(/,/^)/p' "$REPO/install-system.sh" \
    | sed -n 's/^[[:space:]]*"\(.*\)"$/\1/p'
)

# stage <src-dir> <expect-uid> [manifest lines...]  -> exit status, output in $OUT
OUT=""
stage() {
  local src=$1 uid=$2; shift 2
  local out; out=$(mktemp -d "$TMP/stage.XXXXXX")
  OUT=$(python3 -I -S "$STAGER" "$src" "$out" "$uid" "$@" 2>&1)
  local rc=$?
  STAGE_OUT=$out
  return $rc
}

# A pristine copy of the payload, owned by us and mode-correct.
fixture() {
  local dir; dir=$(mktemp -d "$TMP/src.XXXXXX")
  local rel
  for rel in "${RELS[@]}"; do
    mkdir -p "$dir/$(dirname -- "$rel")"
    cp -- "$REPO/$rel" "$dir/$rel"
  done
  chmod -R go-w "$dir"
  printf '%s' "$dir"
}

UID_NOW=$(id -u)

echo "install-system.sh staging"

# 1. the happy path
SRC=$(fixture)
if stage "$SRC" "$UID_NOW" "${SUMS[@]}"; then
  ok "stages every payload file when the folder is untouched"
  n=$(find "$STAGE_OUT" -maxdepth 1 -type f | wc -l)
  check "$n" "${#RELS[@]}" "stages exactly ${#RELS[@]} files and nothing else"
  # the staged bytes are the repo's bytes
  same=yes
  for rel in "${RELS[@]}"; do
    cmp -s "$REPO/$rel" "$STAGE_OUT/${rel//\//_}" || same=no
  done
  check "$same" yes "staged bytes are identical to the committed files"
else
  bad "stages every payload file when the folder is untouched" "$OUT"
fi

# 2. a modified payload file is refused
SRC=$(fixture)
printf '\n# tampered\n' >> "$SRC/${RELS[0]}"
stage "$SRC" "$UID_NOW" "${SUMS[@]}"
check "$?" 1 "refuses a payload file whose bytes changed"
case $OUT in *"does not match the digest"*) ok "names the digest mismatch";;
  *) bad "names the digest mismatch" "$OUT";; esac
check "$(find "$STAGE_OUT" -type f | wc -l)" 0 "installs nothing when a digest fails"

# 3. a payload file replaced by a symlink is refused, and the target is not read
SRC=$(fixture)
secret="$TMP/secret"; printf 'root-only\n' > "$secret"
rm -- "$SRC/${RELS[0]}"; ln -s "$secret" "$SRC/${RELS[0]}"
stage "$SRC" "$UID_NOW" "${SUMS[@]}"
check "$?" 1 "refuses a payload file that is a symlink"
case $OUT in *"cannot open"*|*"Too many levels of symbolic links"*) ok "refuses it at open(), without following it";;
  *) bad "refuses it at open(), without following it" "$OUT";; esac
check "$(grep -rl 'root-only' "$STAGE_OUT" 2>/dev/null | wc -l)" 0 "never copies the symlink target"

# 4. a symlinked directory component is refused too
SRC=$(fixture)
real=$(mktemp -d "$TMP/elsewhere.XXXXXX"); cp -- "$REPO/${RELS[0]}" "$real/"
rm -rf -- "$SRC/system"; ln -s "$real" "$SRC/system"
stage "$SRC" "$UID_NOW" "${SUMS[@]}"
check "$?" 1 "refuses a symlink in place of the system/ directory"

# 5. a FIFO cannot stall or satisfy the install
SRC=$(fixture)
rm -- "$SRC/${RELS[0]}"; mkfifo "$SRC/${RELS[0]}"
timeout 10 python3 -I -S "$STAGER" "$SRC" "$(mktemp -d "$TMP/stage.XXXXXX")" "$UID_NOW" "${SUMS[@]}" >/dev/null 2>&1
rc=$?
case $rc in 1) ok "refuses a FIFO in place of a payload file";;
  124) bad "refuses a FIFO in place of a payload file" "timed out — the open blocked";;
  *) bad "refuses a FIFO in place of a payload file" "exit $rc";; esac

# 6. an extra hard link means someone else still has a handle on the inode
SRC=$(fixture)
ln -- "$SRC/${RELS[0]}" "$TMP/extra-link.$$"
stage "$SRC" "$UID_NOW" "${SUMS[@]}"
check "$?" 1 "refuses a payload file with extra hard links"
rm -f -- "$TMP/extra-link.$$"

# 7. group- or world-writable payload
SRC=$(fixture); chmod g+w "$SRC/${RELS[0]}"
stage "$SRC" "$UID_NOW" "${SUMS[@]}"
check "$?" 1 "refuses a group-writable payload file"

SRC=$(fixture); chmod o+w "$SRC/${RELS[0]}"
stage "$SRC" "$UID_NOW" "${SUMS[@]}"
check "$?" 1 "refuses a world-writable payload file"

# 8. group- or world-writable plugin folder: anyone could rename entries in it
SRC=$(fixture); chmod o+w "$SRC"
stage "$SRC" "$UID_NOW" "${SUMS[@]}"
check "$?" 1 "refuses a world-writable plugin folder"
chmod o-w "$SRC"

SRC=$(fixture); chmod o+w "$SRC/system"
stage "$SRC" "$UID_NOW" "${SUMS[@]}"
check "$?" 1 "refuses a world-writable system/ directory"
chmod o-w "$SRC/system"

# 9. files belonging to someone other than the user who asked for the install
SRC=$(fixture)
stage "$SRC" "$((UID_NOW + 1))" "${SUMS[@]}"
check "$?" 1 "refuses payload files owned by anyone but root or the requesting user"

# 10. the digest list itself is validated before it is trusted
SRC=$(fixture)
stage "$SRC" "$UID_NOW"
check "$?" 1 "refuses to install with no digests recorded"

stage "$SRC" "$UID_NOW" "deadbeef  system/omarchy-vpn-helper"
check "$?" 1 "refuses a malformed digest"

stage "$SRC" "$UID_NOW" "${SUMS[0]}" "${SUMS[0]}"
check "$?" 1 "refuses a duplicated digest entry"

stage "$SRC" "$UID_NOW" "$(printf '%064d  ../../etc/shadow' 0)"
check "$?" 1 "refuses a path that climbs out of the plugin folder"

stage "$SRC" "$UID_NOW" "$(printf '%064d  /etc/shadow' 0)"
check "$?" 1 "refuses an absolute path"

# 11. size cap
SRC=$(fixture)
head -c $((2 * 1024 * 1024)) /dev/zero > "$SRC/${RELS[0]}"
chmod go-w "$SRC/${RELS[0]}"
stage "$SRC" "$UID_NOW" "${SUMS[@]}"
check "$?" 1 "refuses a payload file over the size cap"

echo
echo "release hygiene"

# 12. digests match the files they pin
"$REPO/tools/update-digests.sh" --check >/dev/null 2>&1
check "$?" 0 "recorded digests match the payload files"

# 13. one entry per payload file, no stale or missing lines
check "${#SUMS[@]}" "${#RELS[@]}" "one recorded digest per PAYLOAD entry"

# 14. the flattened staging names cannot collide
uniq_names=$(printf '%s\n' "${RELS[@]//\//_}" | sort -u | wc -l)
check "$uniq_names" "${#RELS[@]}" "staging names are unique across the payload"

# 15. every destination resolves to an absolute path outside the plugin folder
abs=yes
eval "$(sed -n 's/^\(LIBDIR\|POLKIT_ACTION\|DISPATCHER\|UNIT\)=\(\/.*\)$/\1=\2/p' \
        "$REPO/install-system.sh")"
while IFS= read -r dest; do
  eval "dest=\"$dest\""
  [[ $dest == /* && $dest != "$HOME"/* ]] || abs=no
done < <(
  sed -n '/^PAYLOAD=(/,/^)/p' "$REPO/install-system.sh" \
    | sed -n 's/.*:\([^:"]*\)"$/\1/p'
)
check "$abs" yes "every PAYLOAD destination is absolute and outside the home directory"

# 16. the panel's "needs a re-run" check covers exactly what Setup installs
mapfile -t STALE_SRC < <(
  sed -n '/^      "system\/omarchy-vpn-helper:/,/^    do$/p' "$REPO/vpn.sh" \
    | sed -n 's/^[[:space:]]*"\([^:"]*\):.*/\1/p' | sort
)
check "$(printf '%s\n' "${STALE_SRC[@]}")" "$(printf '%s\n' "${RELS[@]}" | sort)" \
  "vpn.sh checks staleness for exactly the files install-system.sh installs"

# 17. the shipped scripts parse
for f in "$REPO"/*.sh "$REPO"/tools/*.sh "$REPO"/tests/*.sh "$REPO/system/omarchy-vpn-helper" "$REPO/system/50-omarchy-vpn"; do
  bash -n "$f" 2>/dev/null || bad "$(basename -- "$f") parses" "syntax error"
done
ok "every shipped shell script parses"

# 18. nothing root runs is executed out of the plugin folder
case $(sed -n '/^ExecStart=/p;/^ExecStop=/p' "$REPO/system/omarchy-vpn-killswitch.service") in
  */home/*|*'$HOME'*|*.config*) bad "the unit never executes anything from a home directory";;
  *) ok "the unit never executes anything from a home directory";;
esac
if grep -qE '(^|[^-])(/home/|\$HOME|\.config/omarchy/plugins)' "$REPO/system/omarchy-vpn-helper" "$REPO/system/50-omarchy-vpn"; then
  bad "the root-executed helper and dispatcher touch no path under a home directory"
else
  ok "the root-executed helper and dispatcher touch no path under a home directory"
fi

echo
echo "public-IP ingest"

# ------------------------------------------------- the one untrusted input
# `refresh-ip` is the only place this plugin reads a third-party HTTP response,
# and the endpoint behind it is user-configurable. These run the real vpn.sh in a
# throwaway HOME with a stubbed curl, so what is exercised is the shipped code
# path rather than a re-implementation of it.
IPT="$TMP/ip"; mkdir -p "$IPT/bin"

# Stub curl: emits the fixture in small chunks and records how many bytes it
# managed to write before the reader went away. That byte count is what proves
# an over-sized transfer is actually cut short rather than merely ignored.
cat > "$IPT/bin/curl" <<'STUB'
#!/usr/bin/env bash
# SIGPIPE has to be ignored, not handled: if the reader's cap closes the pipe
# and the default disposition kills this shell, the byte count is never recorded
# and the check silently reads whatever a previous run left behind.
written=0
trap '' PIPE
trap 'printf "%s" "$written" > "$STUB_WROTE"' EXIT
[[ -n ${STUB_RC:-} && $STUB_RC != 0 ]] && exit "$STUB_RC"
while IFS= read -r -d '' -n 4096 chunk || [[ -n $chunk ]]; do
  printf '%s' "$chunk" 2>/dev/null || break
  written=$((written + ${#chunk}))
done < "$STUB_BODY"
STUB
chmod +x "$IPT/bin/curl"

# refresh <fixture-file> [curl-rc] -> published cache in $IPCACHE
IPCACHE=""
refresh() {
  local home="$IPT/home"; rm -rf -- "$home"; mkdir -p "$home"
  rm -f -- "$IPT/wrote"          # never let a previous run's count be read back
  IPCACHE="$home/state/omarchy-vpn/pubip.json"
  STUB_BODY=$1 STUB_WROTE="$IPT/wrote" STUB_RC=${2:-0} \
  HOME="$home" XDG_STATE_HOME="$home/state" XDG_CONFIG_HOME="$home/config" \
  XDG_RUNTIME_DIR="$home/run" PATH="$IPT/bin:$PATH" \
  OMARCHY_VPN_PUBLICIPURL="https://example.invalid/json" \
    bash "$REPO/vpn.sh" refresh-ip >/dev/null 2>&1
}
# jq's // treats false as empty, so a published {"ok":false} would read as
# absent. Test for presence explicitly instead.
field() { jq -r "$1 | if . == null then \"<absent>\" else tostring end" \
            < "$IPCACHE" 2>/dev/null || echo "<unreadable>"; }

MAXB=$(sed -n 's/^PUBIP_MAX_BYTES=\([0-9]*\)$/\1/p' "$REPO/vpn.sh")
MAXF=$(sed -n 's/^PUBIP_MAX_FIELD=\([0-9]*\)$/\1/p' "$REPO/vpn.sh")
MAXO=$(sed -n 's/^PUBIP_MAX_OUTPUT=\([0-9]*\)$/\1/p' "$REPO/vpn.sh")
check "$([[ -n $MAXB && -n $MAXF && -n $MAXO ]] && echo yes)" yes "the response bounds are declared as constants"

# 19. the happy path still works
printf '%s' '{"ip":"203.0.113.9","city":"Auckland","country":"NZ","org":"AS64496 Example"}' > "$IPT/good.json"
refresh "$IPT/good.json"
check "$(field .ok)"      true         "a normal answer is accepted"
check "$(field .ip)"      "203.0.113.9" "the address is read"
check "$(field .city)"    "Auckland"    "the city is read"
check "$(field .country)" "NZ"          "the country is read"

# 20. an unbounded body is cut off mid-transfer, not slurped and then judged
python3 -c "
import json,sys
sys.stdout.write(json.dumps({'ip':'203.0.113.9','city':'A'*10*1024*1024}))
" > "$IPT/huge.json"
refresh "$IPT/huge.json"
check "$(field .ok)" false "a 10 MB answer is refused"
wrote=$(cat "$IPT/wrote" 2>/dev/null || echo "")
if [[ -z $wrote ]]; then
  bad "the over-sized transfer is stopped early" "the stub recorded no byte count"
elif (( wrote > 0 && wrote < 1048576 )); then
  ok "the over-sized transfer is stopped early (server wrote ${wrote}B of 10 MB)"
else
  bad "the over-sized transfer is stopped early" "server managed to write ${wrote} bytes"
fi

# 21. the boundary itself: at the cap is fine, one byte over is refused
python3 -c "
import sys
cap = $MAXB
head = '{\"ip\":\"203.0.113.9\",\"city\":\"'
tail = '\"}'
sys.stdout.write(head + 'x'*(cap-len(head)-len(tail)) + tail)
" > "$IPT/exact.json"
check "$(wc -c < "$IPT/exact.json")" "$MAXB" "fixture is exactly at the cap"
refresh "$IPT/exact.json"
check "$(field .ok)" true "a body exactly at the cap is accepted"
{ cat "$IPT/exact.json"; printf ' '; } > "$IPT/over.json"
refresh "$IPT/over.json"
check "$(field .ok)" false "one byte past the cap is refused"

# 22. a truncated prefix that is still valid JSON must not be accepted
python3 -c "
import sys
cap = $MAXB
doc = '{\"ip\":\"203.0.113.9\"}'
sys.stdout.write(doc + ' '*(cap*2 - len(doc)))
" > "$IPT/prefixvalid.json"
refresh "$IPT/prefixvalid.json"
check "$(field .ok)" false "an over-long body whose prefix parses is still refused"

# 23. field lengths are bounded inside an otherwise small document
python3 -c "
import json,sys
sys.stdout.write(json.dumps({'ip':'203.0.113.9','city':'B'*4000}))
" > "$IPT/longfield.json"
refresh "$IPT/longfield.json"
city=$(field .city)
check "${#city}" "$MAXF" "an over-long field is cut to the field limit"

# 24. control characters never reach the cache
printf '%s' '{"ip":"203.0.113.9","city":"Auck\u0007land\u001b[31m","country":"N\u0000Z"}' > "$IPT/ctrl.json"
refresh "$IPT/ctrl.json"
if LC_ALL=C grep -qP '[\x00-\x1f\x7f]' <<<"$(field .city)$(field .country)"; then
  bad "control characters are stripped from every field"
else
  ok "control characters are stripped from every field"
fi

# 25. documents that are not objects
for bad_doc in '[1,2,3]' '42' '"hello"' 'null'; do
  printf '%s' "$bad_doc" > "$IPT/nonobj.json"
  refresh "$IPT/nonobj.json"
  [[ $(field .ok) == false ]] || bad "a non-object document ($bad_doc) is refused"
done
ok "a non-object document is refused"

# 26. malformed and empty answers, and a failing request
printf '%s' 'not json at all' > "$IPT/bad.json"; refresh "$IPT/bad.json"
check "$(field .ok)" false "a non-JSON answer is refused"
: > "$IPT/empty.json"; refresh "$IPT/empty.json"
check "$(field .ok)" false "an empty answer is refused"
refresh "$IPT/good.json" 7
check "$(field .ok)" false "a failed request publishes an unavailable marker"

# 27. structured values where a scalar was expected
printf '%s' '{"ip":{"v4":"203.0.113.9"},"city":["A"],"org":{"asn":"AS1"}}' > "$IPT/struct.json"
refresh "$IPT/struct.json"
check "$(field .ok)"   true "a document with structured fields still parses"
check "$(field .ip)"   "<absent>" "an object in the address field is dropped"
check "$(field .city)" "<absent>" "an array in the city field is dropped"

# 28. the address field has to look like an address
printf '%s' '{"ip":"<img src=x onerror=alert(1)>","city":"Auckland"}' > "$IPT/markup.json"
refresh "$IPT/markup.json"
check "$(field .ip)"   "<absent>"  "a non-address in the address field is dropped"
check "$(field .city)" "Auckland"  "the rest of the document survives it"

# 29. a nested lookup that is not an object must not abort the whole parse
printf '%s' '{"ip":"203.0.113.9","connection":"nope"}' > "$IPT/nested.json"
refresh "$IPT/nested.json"
check "$(field .ok)" true "a scalar where a nested object was expected is tolerated"

# 30. whatever happened, the cache is a bounded JSON object and nothing is left behind
allgood=yes; leftover=no
for f in good huge exact over longfield ctrl bad empty struct markup nested; do
  refresh "$IPT/$f.json"
  jq -e 'type == "object"' >/dev/null 2>&1 < "$IPCACHE" || allgood=no
  (( $(wc -c < "$IPCACHE") <= MAXO )) || allgood=no
  found=$(find "$(dirname -- "$IPCACHE")" -name 'pubip.json.*' 2>/dev/null | head -1)
  [[ -n $found ]] && leftover=yes
done
check "$allgood" yes "every outcome publishes a bounded JSON object"
check "$leftover" no  "no staging file is left in the state directory"

# 31. publication is a rename, and an over-sized candidate leaves the old file alone
refresh "$IPT/good.json"
before=$(cat "$IPCACHE")
( set +e
  # shellcheck disable=SC1090
  source <(sed -n '/^pubip_publish()/,/^}/p' "$REPO/vpn.sh")
  PUBIP_CACHE="$IPCACHE" PUBIP_MAX_OUTPUT=$MAXO
  head -c $((MAXO + 4096)) /dev/zero | tr '\0' 'x' | pubip_publish
) >/dev/null 2>&1
check "$(cat "$IPCACHE")" "$before" "an over-sized candidate leaves the published file untouched"
grep -q 'mv -f -- "$tmp" "$PUBIP_CACHE"' "$REPO/vpn.sh" \
  && ok "the cache is published by rename, not written in place" \
  || bad "the cache is published by rename, not written in place"

# 32. the transport policy the reviewer asked to keep
rip=$(sed -n '/^cmd_refresh_ip()/,/^}/p' "$REPO/vpn.sh")
for flag in "--proto '=https'" "--tlsv1.2" "--max-time" "--max-filesize" "head -c"; do
  grep -qF -- "$flag" <<<"$rip" || bad "refresh-ip still uses $flag"
done
ok "HTTPS-only, the timeout, the header cap and the read cap are all still in place"
grep -qE '^\s*\[\[ \$SET_IP_URL =~ \^https:// \]\]' <<<"$rip" \
  && ok "a non-HTTPS endpoint is refused before any request" \
  || bad "a non-HTTPS endpoint is refused before any request"

# 33. the lookup can still be switched off entirely
refresh "$IPT/good.json" 0
( export OMARCHY_VPN_PUBLICIPLOOKUP=false
  home="$IPT/home"
  STUB_BODY="$IPT/good.json" STUB_WROTE="$IPT/wrote" \
  HOME="$home" XDG_STATE_HOME="$home/state" XDG_CONFIG_HOME="$home/config" \
  XDG_RUNTIME_DIR="$home/run" PATH="$IPT/bin:$PATH" \
    bash "$REPO/vpn.sh" refresh-ip >/dev/null 2>&1 )
check "$(field .disabled)" true "turning the lookup off publishes the disabled marker"

# 34. a cache that parses but is not an object must not reach the status JSON
refresh "$IPT/good.json"
printf '%s' '[1,2,3]' > "$IPCACHE"
st=$( HOME="$IPT/home" XDG_STATE_HOME="$IPT/home/state" XDG_CONFIG_HOME="$IPT/home/config" \
      XDG_RUNTIME_DIR="$IPT/home/run" PATH="$IPT/bin:$PATH" \
      bash "$REPO/vpn.sh" status 2>/dev/null )
check "$(jq -c '.public' <<<"$st" 2>/dev/null)" '{}' \
  "status replaces a non-object cache with an empty object"

# 35. status survives a hand-written oversized cache
refresh "$IPT/good.json"
python3 -c "
import json,sys
sys.stdout.write(json.dumps({'ok':True,'city':'C'*(1024*512)}))
" > "$IPCACHE"
st=$( HOME="$IPT/home" XDG_STATE_HOME="$IPT/home/state" XDG_CONFIG_HOME="$IPT/home/config" \
      XDG_RUNTIME_DIR="$IPT/home/run" PATH="$IPT/bin:$PATH" \
      bash "$REPO/vpn.sh" status 2>/dev/null )
if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$st"; then
  check "$(jq -r '.public.city // "<absent>"' <<<"$st")" "<absent>" \
    "status ignores an oversized cache rather than embedding it"
else
  bad "status ignores an oversized cache rather than embedding it" "status produced no JSON"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
