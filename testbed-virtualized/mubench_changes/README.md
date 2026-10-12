# muBench changes

[muBench](https://github.com/mSvcBench/muBench) generates and deploys the microservice
application and sends it the load. The experiments used it at the commit below with the
changes below; `testbed/` expects the checkout at `muBench/` one level above this
repository (or wherever `MUBENCH` points).

| Item | Value |
|---|---|
| Commit the experiments used | `176c8f14f2740414436078d5dcd969d38dd4acd4` (main, 2025-06-12); `apply-changes.sh` takes the latest commit unless `--pinned` |
| Service image | `harbor.crownlabs.polito.it/cloud-sandbox/s324163/mubenchcustom/microservice-screen:latest` (muBench's service cell with `stress-ng`; pulled without credentials) |
| Python | 3.12, packages in `requirements-venv.txt`, installed by hand into `.venv` in the muBench folder (see Install) |

## Files

| Path | What it is |
|---|---|
| `apply-changes.sh` | clones muBench one level above the repository (if needed), at the latest commit or with `--pinned` at the experiments' one, copies `files/` over it, puts `requirements-venv.txt` in place of `requirements.txt`, unzips the Alibaba traces; the `.venv` is yours to create (see Install) |
| `files/` | the changed and added files, at their path in muBench |
| `changes.patch` | the code and configuration changes as a diff, for review |
| `requirements-venv.txt` | the package versions the tests ran with; `apply-changes.sh` installs it as muBench's `requirements.txt` (upstream's pins no longer install on Python 3.12) |
| `monitoring/install-monitoring.sh` | run after muBench's own monitoring install: pins Prometheus, Grafana, kube-state-metrics and the Prometheus operator to the control plane |
| `monitoring/mubench-dashboard.json`, `monitoring/import-dashboard.sh` | the µBench Grafana dashboard and its import |

### What changed in muBench

**Application and deployer**

- `CustomFunctions/run_stress_ng.py` (new): the heavy services' function, `stress-ng
  --cpu <n> --cpu-ops <ops>` per request.
- `Deployers/K8sDeployer/K8sYamlBuilder.py`, `Templates/DeploymentTemplate.yaml`: the
  Deployments are built as objects instead of text, adding resource requests, preferred
  node affinity on `size` or `group` (heavy services), required node labels (anchors),
  preferred pod affinity (probe → anchor) and pod anti-affinity; termination grace
  period 30 s.
- `Templates/DeploymentNginxGwTemplate.yaml`: the gateway runs on the control plane, so
  the load's entry point never moves when workers are removed (it also names a pull
  secret `regcred`, which the public nginx image does not need).
- `Add-on/HPA/hpa-template.yaml`: HPA from 2 to 9 replicas at 70 % CPU, one pod per minute
  up and down.
- `Configs/K8sParameters.json`: the custom image, cluster DNS `kube-dns`, work model
  `SimulationWorkspace/workmodel.json`.
- `Configs/WorkModelParameters.json`: the generator's parameters (Alibaba app24 service
  graph, `run_stress_ng` functions, sizes); kept for reference, the work model below is
  what runs.

**Load**

- `Benchmarks/TrafficGenerator/TrafficGenerator.py`: each request goes to an ingress
  service drawn at random from the list (Poisson arrivals, as upstream).
- `Benchmarks/Runner/Runner.py`: 10 s between workload files instead of 100 s.
- `Configs/TrafficParameters-<n>.json` (new): one recipe per load step, 0 to 6 (6 is
  unused), and S0–S5 (100 requests to one service, for the base latency).
- `Configs/RunnerParameters.json`: steps 0–5 then back down 4–0 (`workload-<n>d.json`
  are copies), file-driven, 500 threads, gateway `http://192.168.111.100:31113` (the
  control plane's address). `RunnerParametersS.json` (new) runs the S0–S5 files.

**Inputs the tests deploy and send** (`SimulationWorkspace/`, ignored by muBench's git)

- `workmodel.json`: 6 heavy services `s0`–`s5` (`run_stress_ng`, 1–3 CPUs requested,
  preferred groups), 4 anchors `aa`–`ad` and 4 probes `pa`–`pd` (each probe prefers its
  anchor's node and calls it 10 times per request). It was edited by hand after
  generation: do not regenerate it. `testbed/deploy-mubench.sh` renders it for `--anchors`.
- `workload-0.json` … `workload-5.json`, `workload-S0.json` … `workload-S5.json`: the
  request traces generated from the TrafficParameters. Generation is random, so the exact
  files are shipped: every run sends the same requests.

**Other**: `requirements.txt` replaced by `requirements-venv.txt` (PyYAML 6.0.3 instead of
5.4.1, plus packaging, setuptools and wheel); `welcome.sh` and
`Monitoring/kubernetes-full-monitoring/monitoring-install.sh` made executable.

## Install

```bash
cd $REPO/mubench_changes
./apply-changes.sh                                   # -> $UPSTREAM/muBench at the latest commit
# ./apply-changes.sh --pinned                        #    or at the experiments' commit (warns: may no longer work)

cd $UPSTREAM/muBench                     # then install muBench as its manual says (Docs/Manual.md):
python3 -m venv .venv                    # inside the muBench folder: the test scripts use .venv/bin/python3
.venv/bin/pip install wheel
.venv/bin/pip install -r requirements.txt   # the versions the tests ran with (~6 min)

# monitoring: muBench's install, against the workload cluster (needs Calico)
export KUBECONFIG=~/workload.kubeconfig
cd $UPSTREAM/muBench/Monitoring/kubernetes-full-monitoring
sh ./monitoring-install.sh                           # Prometheus, Grafana, Istio, Jaeger, Kiali
kubectl apply -f mub-monitor.yaml                    # PodMonitor of the muBench pods
unset KUBECONFIG

cd $REPO/mubench_changes
monitoring/install-monitoring.sh                     # pins the monitoring stack to the control plane
monitoring/import-dashboard.sh                       # µBench dashboard into Grafana
```

The workload itself is deployed by the test scripts (`testbed/deploy-mubench.sh`), not
by muBench's deployer.
