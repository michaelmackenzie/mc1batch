#!/bin/bash
# mc1batch task script: runs one array task on an MC-1 compute node.
#
# The sbatch wrapper written by bin/mc1batch unpacks this script and the job
# files (job.fcl or user.sh, inputs.txt, any --ship files) into $MC1_WORK and
# execs it with the MC1_* variables set. MC1_EXE says what a task runs:
#   mu2e    mu2e -c job.fcl [-S inputs] [-n N] <extra>; outputs are the new
#           .root/.art files in the work directory
#   script  bash user.sh <args>; outputs are the files it leaves in $MC1_OUTPUT_DIR
# With MC1_COPYOUT_ONLY=1 it only retries the copy-out of a stranded task
# (used by "mc1batch recover").
#
# Exit codes (also written to status/<task>):
#   0 ok   1 setup failed   2 mu2e/script failed   3 copy-out failed (outputs kept
#   on the node, see "mc1batch recover")   4 no token   5 no inputs

set -u
tag=$(printf %06d "$MC1_TASK")
export MC1_SLURM_JOB=${MC1_SLURM_JOB:-${SLURM_JOB_ID:-}}
dest_path="$MC1_XRD_PATH/$MC1_NAME/$MC1_ID"
token="/scratch/$MC1_USER/mc1batch/.token/bt"
pending="/data-local/$MC1_USER/mc1batch/$MC1_NAME/$MC1_ID/pending/$tag"

# Copy one local file to $dest_path/<rel>, replacing any older copy
# (dCache does not overwrite in place).
put() {
    local src=$1 rel=$2 try
    xrdfs "$MC1_XRD_HOST" rm "$dest_path/$rel" >/dev/null 2>&1
    for try in 1 2 3; do
        xrdcp -s -p "$src" "$MC1_XRD_HOST/$dest_path/$rel" && return 0
        echo "mc1batch: xrdcp of $rel failed (try $try)"
        sleep 30
    done
    return 1
}

# Copy outputs, then the log, then the status file (written last, so its
# presence means the task is complete).
copyout() {
    local rc=$1 f
    for f in $(cat outputs.txt 2>/dev/null); do
        put "$f" "$f" || return 1
    done
    put task.log "logs/$tag.log" || return 1
    {
        echo "rc=$rc"
        echo "node=$(hostname -s)"
        echo "slurm_job=$MC1_SLURM_JOB"
        echo "exe_rc=${MC1_EXE_RC:-}"
        echo "start=${MC1_START:-}"
        echo "end=$(date -Is)"
        echo "outputs=$(tr '\n' ' ' < outputs.txt 2>/dev/null)"
    } > status.txt
    put status.txt "status/$tag" || return 1
}

finish() {
    local rc=$1
    cd "$MC1_WORK" || exit "$rc"
    echo "mc1batch: task $tag rc=$rc, copying out to $dest_path" >> task.log
    if [ -r "$token" ] && copyout "$rc" >> task.log 2>&1; then
        cd / && rm -rf "$MC1_WORK"
        echo "mc1batch: task $tag done rc=$rc" >&3
        exit "$rc"
    fi
    # Keep everything on this node for "mc1batch recover".
    mkdir -p "$(dirname "$pending")" && rm -rf "$pending" && mv "$MC1_WORK" "$pending"
    MC1_EXE_RC=${MC1_EXE_RC:-}
    declare -p MC1_USER MC1_NAME MC1_ID MC1_TASK MC1_XRD_HOST MC1_XRD_PATH MC1_START MC1_SLURM_JOB MC1_EXE_RC \
        > "$pending/env.sh"
    echo "rc=$rc" > "$pending/rc"
    echo "mc1batch: task $tag copy-out failed, kept in $(hostname -s):$pending" >&3
    exit 3
}

export BEARER_TOKEN_FILE=$token
cd "$MC1_WORK" || exit 1

if [ "${MC1_COPYOUT_ONLY:-0}" = 1 ]; then
    exec 3>&1
    rc=$(sed -n 's/^rc=//p' rc 2>/dev/null)
    if [ -r "$token" ] && copyout "${rc:-3}" >> task.log 2>&1; then
        cd / && rm -rf "$MC1_WORK"
        echo "recovered $tag"
        exit 0
    fi
    echo "still failing $tag"
    exit 3
fi

exec 3>&1 >task.log 2>&1
export MC1_START=$(date -Is)
echo "mc1batch: task $tag of $MC1_NAME/$MC1_ID on $(hostname -s) as $(whoami), start $MC1_START"

[ -r "$token" ] || { echo "mc1batch: no token at $token (run 'mc1batch token')"; finish 4; }

cpus=${SLURM_CPUS_PER_TASK:-1}
export OMP_NUM_THREADS=$cpus OPENBLAS_NUM_THREADS=$cpus MKL_NUM_THREADS=$cpus

# The task's share of the inputs.
if [ "$MC1_MODE" = input ]; then
    first=$(( (MC1_TASK - MC1_TASK_OFFSET) * MC1_FPJ + 1 ))
    sed -n "${first},$(( first + MC1_FPJ - 1 ))p" inputs.txt > task_inputs.txt
    [ -s task_inputs.txt ] || { echo "mc1batch: no inputs for task $tag"; finish 5; }
    echo "mc1batch: inputs:"; cat task_inputs.txt
fi
rm -f inputs.txt

set +u
if [ "$MC1_EXE" = mu2e ] || [ -n "$MC1_SETUP" ]; then
    source /cvmfs/mu2e.opensciencegrid.org/setupmu2e-art.sh || finish 1
fi
if [ -n "$MC1_SETUP" ]; then
    eval "$MC1_SETUP" || finish 1
fi
set -u

touch .mc1_start
if [ "$MC1_EXE" = mu2e ]; then
    command -v mu2e >/dev/null || { echo "mc1batch: no mu2e after setup '$MC1_SETUP'"; finish 1; }
    args=(-c job.fcl)
    if [ "$MC1_MODE" = input ]; then
        args+=(-S task_inputs.txt)
    else
        # Generator jobs: give every task its own seed and subrun.
        printf '\nservices.SeedService.baseSeed : %d\nsource.firstSubRun : %d\n' \
            $(( MC1_SEED + MC1_TASK )) "$MC1_TASK" >> job.fcl
    fi
    [ "$MC1_NEVENTS" -gt 0 ] 2>/dev/null && args+=(-n "$MC1_NEVENTS")
    echo "mc1batch: mu2e ${args[*]} $MC1_EXTRA"
    eval mu2e '"${args[@]}"' "$MC1_EXTRA"
    rc=$?
    echo "mc1batch: mu2e exited with $rc"
    produced=$(find . -maxdepth 1 -newer .mc1_start \( -name '*.root' -o -name '*.art' \) -printf '%f\n')
else
    # What the script sees: its inputs, a place for outputs, its task number.
    export MC1_INPUTS=$MC1_WORK/task_inputs.txt MC1_OUTPUT_DIR=$MC1_WORK/out
    [ "$MC1_MODE" = input ] || : > "$MC1_INPUTS"
    mkdir -p "$MC1_OUTPUT_DIR"
    echo "mc1batch: bash user.sh $MC1_EXTRA"
    eval bash ./user.sh "$MC1_EXTRA"
    rc=$?
    echo "mc1batch: user.sh exited with $rc"
    produced=$(find out -maxdepth 1 -type f -printf '%f\n')
    for f in $produced; do mv "out/$f" "./$f" || finish 1; done
fi
MC1_EXE_RC=$rc
[ $rc -eq 0 ] || finish 2

# Rename outputs so tasks do not collide. A Mu2e six-field name gets the task
# number as its sequencer; others get it inserted before the extension.
: > outputs.txt
for f in $produced; do
    IFS=. read -ra p <<< "$f"
    if [ ${#p[@]} -eq 6 ]; then
        new="${p[0]}.${p[1]}.${p[2]}.${p[3]}.$tag.${p[5]}"
    elif [[ $f == *.* ]]; then
        new="${f%.*}.$tag.${f##*.}"
    else
        new="$f.$tag"
    fi
    [ "$f" = "$new" ] || mv "$f" "$new"
    echo "$new" >> outputs.txt
done
echo "mc1batch: outputs: $(tr '\n' ' ' < outputs.txt)"
finish 0
