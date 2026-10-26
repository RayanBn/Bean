import os, pty, sys, time, select

run_dir, term, command, times = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
pid, fd = pty.fork()
if pid == 0:
    os.chdir(run_dir)
    env = dict(os.environ, ZDOTDIR=run_dir, TERM_PROGRAM=term, TERM="xterm-256color")
    os.execve("/bin/zsh", ["zsh", "-i"], env)

def drain(seconds):
    out, end = b"", time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                out += os.read(fd, 4096)
            except OSError:
                break
    return out

drain(1.5)
for _ in range(times):
    os.write(fd, (command + "\n").encode())
    print(drain(1.5).decode(errors="replace").replace("\r", ""), end="")
os.write(fd, b"exit\n")
drain(0.5)
