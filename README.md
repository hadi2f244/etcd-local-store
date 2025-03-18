# etcd-local-restore
A script to restore etcd on a kind cluster 

## Requirments
1. [Docker](https://docs.docker.com/engine/install/ubuntu/)
2. [Kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/#install-kubectl-binary-with-curl-on-linux)

## Description
This script first installs a `kind` cluster named `mycluster` and then restores the etcd snapshot on it.

```
sudo ./restore.sh <etcd_snapshot_file>
```

At the end of the script, there is a `kubectl get node` command that ensures etcd is restored.

## Notes
+ After restoring, the cluster may not work properly; it's better to restart the nodes. Also, in this phase, pods might not work even though `kubectl get pods -A` shows that some pods are present.
