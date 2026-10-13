# mc1batch

Run Mu2e jobs, either `mu2e` with an fcl or any bash script, on the MC-1
Slurm cluster (`mu2e-mc1-worker-02..18`) from an interactive node such as
mu2esrv01, with the outputs landing on dCache:

```
/pnfs/mu2e/scratch/users/$USER/slurm/<name>/<id>/
```

You never log in to the cluster yourself. `mc1batch` reaches it over ssh
(`mu2eshift@g2gateway01` → `mu2ebatch@mu2e-mc1-worker-01`) using your Kerberos
ticket. Inputs are streamed over xrootd and outputs are copied back over xrootd
with your bearer token, so you analyse the results where `/pnfs` is mounted.

## Setup

The package needs nothing but Python 3.9+ and the usual Mu2e interactive
node tools (`ssh`, `htgettoken`, CVMFS). Clone or copy it anywhere, then:

```bash
source <path to mc1batch>/setup.sh
kinit you@FNAL.GOV          # if you have no valid ticket
mc1batch check              # gateway, nodes, token, output area
```

Your principal must be in the `~/.k5login` of `mu2eshift` (gateway) and
`mu2ebatch` (cluster). The cluster's own guide:
`Getting Started with Mu2e Batch in MC-1` (Mu2e/mu2edaq-batch-queues,
`docs/GETTING-STARTED.md`).

## Usage

```bash
# one task per file of a dataset (file names from SAM, paths from mdh)
mc1batch submit myrun -c job.fcl --setup "muse setup SimJob MDC2025ay" \
    --dataset mcs.mu2e.CeEndpointMix1BB-KL.Run1Baw_best_v1_5.art \
    --files-per-job 2 --mem 4G --time 04:00:00

# a quick test first: 2 files, 10 events each
mc1batch submit mytest -c job.fcl --setup "muse setup SimJob MDC2025ay" \
    --dataset <dataset> --max-files 2 -n 10 --time 00:30:00

# an explicit list of /pnfs paths or root:// URLs
mc1batch submit myrun -c job.fcl --setup "..." --files files.txt

# generator jobs, no inputs: baseSeed = --seed + task, firstSubRun = task
mc1batch submit mygen -c gen.fcl --setup "..." --njobs 100 -n 10000 --seed 1000

# any bash script instead of mu2e (see "Script mode" below)
mc1batch submit myana --script ana.sh --ship ana.py --args "--cut 5" \
    --setup "pyenv ana" --dataset <dataset> --files-per-job 5

mc1batch status myrun          # latest submission of "myrun" (or myrun/<id>)
mc1batch resubmit myrun/87     # rerun failed tasks into the same directory
mc1batch recover myrun/87      # copy back outputs stranded on node disks
mc1batch clean myrun/87        # delete node-local leftovers when finished
mc1batch list                  # all submissions and how many tasks are ok
mc1batch token [--watch]       # refresh the token on all nodes
```

`<id>` is the Slurm job id of the first array. `--max-running N` caps how many
tasks run at once; the cluster is shared, so use it for big submissions.
`--dry-run` prints the batch script header without submitting.

## Script mode

`--script my.sh` runs `bash my.sh <--args>` in each task instead of `mu2e`.
The script starts in the task's work directory on the compute node, with:

| variable | meaning |
|----------|---------|
| `MC1_INPUTS` | file listing this task's input URLs (`root://...`), one per line; empty for `--njobs` |
| `MC1_OUTPUT_DIR` | put the files to keep here; everything in it is copied to /pnfs |
| `MC1_TASK` | task number (0, 1, ...) |
| `MC1_NEVENTS`, `MC1_SEED` | the `-n` and `--seed` values, if you want them |
| `BEARER_TOKEN_FILE` | your token, so `xrdcp`, ROOT and uproot can read `root://` URLs |
| `SLURM_CPUS_PER_TASK`, `OMP_NUM_THREADS` | the `--cpus` you asked for |

- `--setup` is optional here. When given, `setupmu2e-art.sh` is sourced and
  the setup command run before the script, so the script inherits the
  environment (`PATH`, `ROOTSYS`, python, ...). Shell functions such as `muse`
  itself are not inherited; a script that needs them sources
  `setupmu2e-art.sh` itself. Without `--setup` the script runs in the
  node's plain environment.
- `--ship file` (repeatable) puts small helper files (a python module, a
  macro, an fcl) next to the script. Keep them small: they travel inside
  the batch script, which Slurm limits to 4 MB.
- A non-zero exit code fails the task (rc 2); its exit code is shown by
  `status`, and its outputs are not copied.
- Write scratch files anywhere in the work directory, as only
  `$MC1_OUTPUT_DIR` is copied.

## What ends up on /pnfs

```
<name>/<id>/
  manifest.json      command, setup, resources, Slurm arrays
  job/               the fcl or script and shipped files as submitted
  inputs.txt         the input URLs (input mode)
  <outputs>          mu2e: every new .root/.art file; script: $MC1_OUTPUT_DIR
  logs/<task>.log    the full task log
  status/<task>      rc, node, slurm job, times, output names (written last)
```

Outputs are renamed so that tasks do not collide: a Mu2e six-field name gets
the task number as its sequencer (`nts.me.desc.v0.sequencer.root` →
`nts.me.desc.v0.000012.root`), any other name gets it appended before the
extension (`hist.root` → `hist.000012.root`).

## Task exit codes

| rc | meaning | what to do |
|----|---------|------------|
| 0 | ok | |
| 1 | `--setup` failed, or gave no `mu2e` | check the log, fix the setup string |
| 2 | `mu2e` or the script failed (its own exit code is in `status`) | check the log |
| 3 | copy-out failed; outputs kept on the node (`stranded`) | `mc1batch recover` |
| 4 | no token on the node | `mc1batch token`, then `resubmit` |
| 5 | no inputs for this task | |

`status` uses each task's latest Slurm attempt (`sacct`) together with its
status file, so a failed rerun is never hidden by an older success. Tasks
killed by Slurm (timeout, out of memory, node failure) show up as `failed` with
the Slurm state; rerun them with `resubmit --mem/--time`.

## Things to know

- **No shared filesystem on the cluster.** Each task runs in
  `/scratch/$USER/mc1batch/<name>/<id>/<task>` on its node and deletes it at
  the end. Only CVMFS is available, so the software must come from a CVMFS
  release (`muse setup SimJob <version>`, `muse setup EventNtuple ...`,
  `pyenv ana`); a local muse build cannot be used yet. The fcl's `#include`s
  must resolve in that release.
- **Inputs must be on disk.** xrootd cannot recall files that are only on
  tape (dCache `NEARLINE`). `submit` checks up to 200 inputs through the
  local `/pnfs` mount and refuses if any are tape-only; stage them first with
  `mdh prestage-files <dataset or file names>` (after `muse setup ops`), which
  can take hours for a large dataset. `--skip-stage-check` overrides.
- **Copy-out uses the node's own xrootd client** (`/usr/bin/xrdcp`, clean
  environment), because the `xrdcp` from an older release set up by `--setup`
  cannot authenticate with a token. The same may apply to reading inputs
  with ROOT from an old release; prefer a recent release.
- **The token.** Jobs have no Kerberos ticket, so your bearer token (from
  `htgettoken`, valid ~3 h) is copied to
  `/scratch/$USER/mc1batch/.token/bt` on every node at each submit, readable
  only by `mu2ebatch`. But **everyone authorised for mu2ebatch can read it**.
  Only the short-lived access token is copied, never the vault token. For
  jobs that outlive it, keep `mc1batch token --watch` running (e.g. in tmux);
  it refreshes every hour and stops when your jobs are gone. Remove the token
  with `mc1batch token --remove` when you are done.
- **Write permission.** The token can write under
  `/pnfs/mu2e/scratch/users/$USER`, which is why that is the output base.
  `MC1_OUTBASE` changes it.
- **Large submissions** are split into arrays of up to 1001 tasks (Slurm's
  `MaxArraySize`). Each array's batch script carries its slice of the input
  list, which keeps it under Slurm's 4 MB script limit for up to ~20 files
  per task.
- **Slurm's own stdout** goes to `/data-local/$USER/mc1batch/slurm/` on the
  node, but it holds only one line; the real log is `logs/<task>.log`.

## Configuration (environment variables)

| variable | default |
|----------|---------|
| `MC1_GATEWAY` | `mu2eshift@g2gateway01.fnal.gov` |
| `MC1_EXTRA_JUMP` | unset; e.g. `mu2eshift@mu2egateway02.fnal.gov` if g2gateway01 is not reachable directly |
| `MC1_ACCOUNT` | `mu2ebatch` |
| `MC1_SUBMIT_HOST` | `mu2e-mc1-worker-01.fnal.gov` |
| `MC1_PARTITION` | `mc1` |
| `MC1_OUTBASE` | `/pnfs/mu2e/scratch/users/$USER/slurm` |
| `MC1_USER` | `$USER` (names your areas on the cluster) |

The generated ssh config (with connection sharing, so the gateway sees one
login) is in `$XDG_RUNTIME_DIR/mc1batch/`.

## Files

- `bin/mc1batch`: the command (Python 3.9+, standard library only)
- `mc1batch/job.sh`: the task script that runs on the compute node
