#!/usr/bin/env python3
"""Run a command under a pty that answers XTVERSION however the caller says.

    pty_probe.py <answer|-> <command> [args...]

`answer` is a python-escaped byte string sent once the command asks for the
terminal's name; `-` never answers. Prints one line of JSON-ish results:

    elapsed=<seconds> osc=<count> exit=<rc line seen>

This exists because the terminal probe can only be exercised against a real
terminal, and getting it wrong hangs the run rather than failing it.
"""
import os
import pty
import re
import select
import sys
import time

answer = None if sys.argv[1] == "-" else sys.argv[1].encode().decode("unicode_escape").encode("latin-1")
command = sys.argv[2:]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)

chunks, answered, start = [], False, time.time()
while time.time() - start < 10:
    readable, _, _ = select.select([fd], [], [], 0.002)
    if readable:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        chunks.append(chunk)
        if answer and not answered and b"\x1b[>q" in b"".join(chunks):
            os.write(fd, answer)
            answered = True
    if b"__done__" in b"".join(chunks):
        break

output = b"".join(chunks).decode("utf8", "replace")
os.waitpid(pid, os.WNOHANG)
print("elapsed=%.2f osc=%d done=%s" % (
    time.time() - start,
    len(re.findall(r"\x1b\]9;4;\d+;\d+\x07", output)),
    "__done__" in output,
))
