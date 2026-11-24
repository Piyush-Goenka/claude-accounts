# Drives a command in a real terminal (a pty) for tests that need one, and
# prints everything that appeared on screen. Steps, in order:
#   wait:TEXT   wait until TEXT is on screen, then a moment more, so zsh is
#               sitting in its read before input arrives
#   send:TEXT   type TEXT (backslash escapes allowed: \n, \x7f, \x03)
#   sleep:SECS  keep reading the screen for SECS seconds
#   until:TEXT  read the screen until TEXT appears
# Usage: pty_drive.py [--interactive] COMMAND STEP...
#   COMMAND runs as zsh -f -c COMMAND; with --interactive, an interactive
#   zsh starts instead and COMMAND is ignored (send the command as a step).
import os, pty, select, signal, sys, time
args = sys.argv[1:]
interactive = args[:1] == ['--interactive']
if interactive: args = args[1:]
command, steps = args[0], args[1:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp('zsh', ['zsh', '-f', '-i'] if interactive else ['zsh', '-f', '-c', command])
screen = b''
def pump(until=None, seconds=10.0):
    global screen
    end = time.time() + seconds
    while time.time() < end:
        if until is not None and until.encode() in screen:
            return
        if select.select([fd], [], [], 0.05)[0]:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            screen += chunk
for step in steps:
    kind, _, value = step.partition(':')
    value = value.encode().decode('unicode_escape')
    if kind == 'wait':
        pump(value); pump(None, 0.5)
    elif kind == 'send':
        try:
            os.write(fd, value.encode())
        except OSError:
            pass
    elif kind == 'sleep':
        pump(None, float(value))
    elif kind == 'until':
        pump(value)
pump(None, 0.5)
try:
    os.kill(pid, signal.SIGKILL)
except ProcessLookupError:
    pass
os.waitpid(pid, 0)
sys.stdout.write(screen.decode(errors='replace').replace('\r', ''))
