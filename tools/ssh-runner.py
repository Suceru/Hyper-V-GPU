#!/usr/bin/env python3
"""Upload a guest script over SSH and run it (optionally with sudo).

Examples:
    python3 tools/ssh-runner.py guest/02-dxgkrnl-deploy.sh \
        --host 172.20.206.161 --user ubuntu --key ~/.ssh/id_ed25519 --sudo

sudo password: set SUDO_PASS env var or leave unset to be prompted.
"""
import argparse
import getpass
import os
import shlex
import sys
import time

import paramiko


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("script", help="local script to upload and run")
    ap.add_argument("--host", required=True, help="guest IP / hostname")
    ap.add_argument("--user", required=True, help="guest SSH user")
    ap.add_argument("--key", required=True, help="private key path")
    ap.add_argument("--remote-dir", default="~/gpu-pv", help="remote directory (default: ~/gpu-pv)")
    ap.add_argument("--sudo", action="store_true", help="run with sudo (password via SUDO_PASS or prompt)")
    ap.add_argument("--timeout", type=int, default=1800, help="exec timeout seconds (default 1800)")
    args = ap.parse_args()

    sudo_pass = os.environ.get("SUDO_PASS", "")
    if args.sudo and not sudo_pass:
        sudo_pass = getpass.getpass("sudo password: ")

    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(args.host, 22, username=args.user, key_filename=args.key,
                timeout=20, allow_agent=False, look_for_keys=False)
    print(f"[ssh] connected to {args.user}@{args.host}")

    remote_dir = args.remote_dir.replace("~", "", 1) if args.remote_dir.startswith("~") else args.remote_dir
    if args.remote_dir.startswith("~"):
        sftp = cli.open_sftp()
        home = sftp.normalize(".")
        remote_dir = home + remote_dir
    else:
        sftp = cli.open_sftp()
    try:
        sftp.stat(remote_dir)
    except IOError:
        sftp.mkdir(remote_dir)
    remote_script = remote_dir.rstrip("/") + "/" + os.path.basename(args.script)
    sftp.put(args.script, remote_script)
    sftp.close()
    print(f"[sftp] uploaded -> {remote_script}")

    cmd = f"bash {shlex.quote(remote_script)}"
    if args.sudo:
        cmd = f"echo {shlex.quote(sudo_pass)} | sudo -S -p '' bash {shlex.quote(remote_script)}"

    transport = cli.get_transport()
    channel = transport.open_session()
    channel.settimeout(args.timeout)
    channel.exec_command(cmd)
    while True:
        if channel.recv_ready():
            sys.stdout.write(channel.recv(65536).decode("utf-8", "replace"))
            sys.stdout.flush()
        if channel.recv_stderr_ready():
            sys.stderr.write(channel.recv_stderr(65536).decode("utf-8", "replace"))
            sys.stderr.flush()
        if channel.exit_status_ready() and not channel.recv_ready() and not channel.recv_stderr_ready():
            break
        time.sleep(0.1)
    rc = channel.recv_exit_status()
    cli.close()
    print(f"\n[exit] {rc}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
