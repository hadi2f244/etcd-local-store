# etcd-local-restore
A script to restore etcd on kind cluster 

## Requirments
1. [Docker](https://docs.docker.com/engine/install/ubuntu/)
2. [Kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/#install-kubectl-binary-with-curl-on-linux)

## Description
This script first install a `kind` cluster named mycluster and then restore the etcd snapshot on it.

```
sudo ./restore.sh <etcd_snapshot_file>
```

At the end of script, there is a `kubectl get node` command that make sure etcd is restored.

## Notes
+ After restoring the cluster may not work properly, better to restart the nodes. Also, in this phase pods not working although `kubectl get pods -A` shows there are some pods. 

