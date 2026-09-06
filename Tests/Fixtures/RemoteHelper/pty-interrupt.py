#!/usr/bin/python3
import errno
import os
import pty
import select
import signal
import sys
import time

if len(sys.argv) < 3:
    raise SystemExit("usage: pty-interrupt.py MARKER COMMAND...")

marker = sys.argv[1]
command = sys.argv[2:]
child_pid, master_fd = pty.fork()
if child_pid == 0:
    os.execvpe(command[0], command, os.environ)

deadline = time.monotonic() + 15
interrupt_sent = False
wait_status = None
output = bytearray()
try:
    while time.monotonic() < deadline:
        readable, _, _ = select.select([master_fd], [], [], 0.02)
        if readable:
            try:
                chunk = os.read(master_fd, 65536)
                if chunk and len(output) < 1048576:
                    output.extend(chunk[: 1048576 - len(output)])
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
        if not interrupt_sent and os.path.isfile(marker):
            os.write(master_fd, b"\x03")
            interrupt_sent = True
        waited_pid, status = os.waitpid(child_pid, os.WNOHANG)
        if waited_pid == child_pid:
            wait_status = status
            break
    if wait_status is None:
        raise RuntimeError("PTY helper did not exit within the deadline")
    if not interrupt_sent:
        raise RuntimeError("Copilot never reached the interrupt-ready point")
    if not os.WIFEXITED(wait_status) or os.WEXITSTATUS(wait_status) not in (2, 130):
        raise RuntimeError(f"unexpected helper wait status {wait_status}")
except Exception as error:
    try:
        os.killpg(child_pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(child_pid, 0)
    except ChildProcessError:
        pass
    sys.stderr.buffer.write(output)
    print(str(error), file=sys.stderr)
    raise SystemExit(1)
finally:
    os.close(master_fd)
