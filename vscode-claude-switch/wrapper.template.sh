#!/bin/zsh
# claude-switch wrapper (generated file, do not edit by hand).
# The Claude VS Code extension launches this instead of the claude binary
# (real binary arrives as $1, session args follow). It picks the account for
# this window by matching the working directory against map.json, exports
# CLAUDE_CONFIG_DIR for the matching profile, and execs the real binary.
# Fail-open: on any problem it runs claude untouched (default account).

MAP="__MAP_PATH__"
profile=""

if [[ -f "$MAP" ]]; then
  profile=$(/usr/bin/python3 - "$MAP" "$PWD" << 'PY' 2>/dev/null
import json, os, sys, unicodedata
try:
    m = json.load(open(sys.argv[1]))
    cwd = unicodedata.normalize('NFC', os.path.realpath(sys.argv[2]))
    best = name = ''
    for k, v in m.items():
        k2 = unicodedata.normalize('NFC', os.path.realpath(os.path.expanduser(str(k))))
        if (cwd == k2 or cwd.startswith(k2 + os.sep)) and len(k2) > len(best):
            best, name = k2, str(v)
    print(name)
except Exception:
    pass
PY
  )
fi

# "default" is an explicit mapping meaning the default account (~/.claude);
# it exists so a subfolder can override a parent folder's mapping.
if [[ -n "$profile" && "$profile" != default && -d "$HOME/.claude-$profile" ]]; then
  export CLAUDE_CONFIG_DIR="$HOME/.claude-$profile"
fi

# breadcrumb for validation and support; never fatal
echo "$(date '+%F %T') cwd=$PWD profile=${profile:-default} bin=$1" > "${MAP%/*}/last-spawn.log" 2>/dev/null

exec "$@"
