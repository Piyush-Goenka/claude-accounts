#!/bin/zsh -f
# Test suite for claude-accounts. Run from anywhere:  zsh -f tests/run.zsh
# Every test_* function of every tests/test_*.zsh runs in its own subshell
# inside a fresh sandbox (see lib.zsh). Then the VS Code extension tests run
# under node, when tests/extension.test.js exists and node is on PATH.

export CA_REPO=${0:A:h:h}
source "$CA_REPO/tests/lib.zsh"

integer passed=0 failed=0 rc
local file name t
local -a names
for file in "$CA_REPO"/tests/test_*.zsh(N); do
  names=( ${(f)"$(source "$file"; print -l ${(ok)functions[(I)test_*]})"} )
  for name in $names; do
    t=$(mktemp -d "${TMPDIR:-/tmp}/ca-test.XXXXXX")
    ( export CA_T=$t; ca_sandbox; source "$file"; $name; exit $(( CA_FAILS > 0 )) ) \
      </dev/null >"$t.out" 2>&1
    rc=$?
    if (( rc == 99 )); then
      cat "$t.out" >&2; chmod -R u+rwX "$t"; rm -rf "$t" "$t.out"; exit 99
    elif (( rc == 0 )); then
      passed+=1; print -r -- "ok    ${file:t}  $name"
    else
      failed+=1; print -r -- "FAIL  ${file:t}  $name"; sed 's/^/      /' "$t.out"
    fi
    chmod -R u+rwX "$t" 2>/dev/null; rm -rf "$t" "$t.out"
  done
done

if [[ -f "$CA_REPO/tests/extension.test.js" ]] && (( $+commands[node] )); then
  if node --test "$CA_REPO/tests/extension.test.js" >"${TMPDIR:-/tmp}/ca-node.out" 2>&1; then
    passed+=1; print -r -- "ok    extension.test.js  (node --test)"
  else
    failed+=1; print -r -- "FAIL  extension.test.js  (node --test)"; sed 's/^/      /' "${TMPDIR:-/tmp}/ca-node.out"
  fi
  rm -f "${TMPDIR:-/tmp}/ca-node.out"
fi

print -r -- "$passed passed, $failed failed"
(( failed == 0 ))
