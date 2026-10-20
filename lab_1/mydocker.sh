#!/bin/bash

set -e

CGROUP="/sys/fs/cgroup/mydocker"

echo "[mydocker] starting container"

mkdir -p "$CGROUP"

echo $((100 * 1024 * 1024)) > "$CGROUP/memory.max"

echo 0 > "$CGROUP/memory.swap.max"

echo "20000 100000" > "$CGROUP/cpu.max"

echo 20 > "$CGROUP/pids.max" 

unshare --pid --fork --mount --mount-proc --uts --ipc bash -c '
	echo $$ > /sys/fs/cgroup/mydocker/cgroup.procs

	hostname my-container

	echo "[mydocker] PID inside container: $$"
	echo "[mydocker] hostname: $(hostname)"
	echo "[mydocker] memory limits: $(cat /sys/fs/cgroup/mydocker/memory.max)"
	echo "[mydocker] cpu limits: $(cat /sys/fs/cgroup/mydocker/cpu.max)"
	echo "[mydocker] pids limits: $(cat /sys/fs/cgroup/mydocker/pids.max)"

	cd /home/zatikyan/containerization-lab1
	exec capsh --drop=cap_sys_admin,cap_sys_time,cap_net_admin,cap_sys_module -- -c "exec /home/zatikyan/containerization-lab1/.venv/bin/python3 /home/zatikyan/containerization-lab1/api.py"
	'
