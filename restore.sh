#!/bin/bash
set -e

# Step 0: Verify prerequisites are installed (kubectl and docker)
echo "Checking if required tools (kubectl and docker) are installed..."

if ! command -v kubectl &> /dev/null; then
    echo "Error: 'kubectl' is not installed. Please install 'kubectl' before running this script."
    exit 1
fi

if ! command -v docker &> /dev/null; then
    echo "Error: 'docker' is not installed. Please install 'docker' before running this script."
    exit 1
fi

echo "All required tools are installed!"

# Check if the ETCD snapshot path argument is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <etcd_snapshot_path>"
    echo "Error: ETCD snapshot path is required as the first argument."
    exit 1
fi
SNAPSHOT_PATH="$1"

if [ ! -f "$SNAPSHOT_PATH" ]; then
    echo "Error: Snapshot file '$SNAPSHOT_PATH' does not exist."
    exit 1
fi
echo "Using ETCD snapshot path: $SNAPSHOT_PATH"

# Step 1: Check if kind is installed
if ! command -v kind &> /dev/null; then
    echo "kind is not installed. Installing kind..."
    if [ $(uname -m) = x86_64 ]; then
        curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
        chmod +x ./kind
        sudo mv ./kind /usr/local/bin/kind
        echo "kind installed successfully!"
    else
        echo "Error: Unsupported architecture. Please install manually."
        exit 1
    fi
else
    echo "kind is already installed."
fi

# Step 2: Check if mycluster exists
if kind get clusters | grep -q mycluster; then
    read -p "A cluster named 'mycluster' already exists. Do you want to delete it? (y/n): " response
    if [[ "$response" == "y" || "$response" == "Y" ]]; then
        kind delete cluster --name mycluster
    else
        echo "Exiting script. Please delete the cluster manually if needed."
        exit 1
    fi
fi

# Step 3: Create the kind config dynamically
CONFIG_FILE=$(mktemp)
cat <<EOF > "$CONFIG_FILE"
# three node (two workers) cluster config
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
EOF

# Create the kind cluster with embedded config
echo "Creating the 'mycluster' kind cluster..."
kind create cluster --name mycluster --config "$CONFIG_FILE"
rm -f "$CONFIG_FILE"  # Clean up the temporary config file
echo "'mycluster' cluster created successfully!"

# Step 4: Check cluster working status
echo "Checking if the cluster is working..."
if kubectl get pods -A &> /dev/null; then
    echo "Cluster is working and kubectl is functional!"
else
    echo "Cluster is not working. Please troubleshoot the issue."
    exit 1
fi

# Step 5: Validate ETCD snapshot file (already checked above)
echo "Using ETCD snapshot path: $SNAPSHOT_PATH"

# Step 6: Get the master container ID
masterContainerID=$(docker ps -a | grep mycluster-control-plane | awk '{print $1}')
if [ -z "$masterContainerID" ]; then
    echo "Error: Could not find the master container for 'mycluster-control-plane'."
    exit 1
fi
echo "Master container ID: $masterContainerID"

# Step 7: Copy the snapshot file into the container
echo "Copying snapshot file to the master container..."
docker cp "$SNAPSHOT_PATH" "$masterContainerID:/etcd.db"
echo "Snapshot file copied to container successfully!"

# Step 8: Extract IP address dynamically from etcd manifest file
echo "Extracting IP address from /etc/kubernetes/manifests/etcd.yaml inside the container..."
ETCD_IP=$(docker exec -it "$masterContainerID" /bin/bash -c "
    grep -oP -- '--advertise-client-urls=https://\\K[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+' /etc/kubernetes/manifests/etcd.yaml | tr -d '\r'
")
ETCD_URL="https://$(echo $ETCD_IP | tr -d '\r' ):2380"
if [ -z "$ETCD_URL" ]; then
    echo "Error: Could not extract the IP address from /etc/kubernetes/manifests/etcd.yaml."
    exit 1
fi
echo "Extracted etcd url: $ETCD_URL"

# Step 9: Install etcd-client inside the container
echo "Installing etcd-client tools inside the container..."
docker exec -it "$masterContainerID" /bin/bash -c "
    apt-get update && apt-get install -y etcd-client
"
echo "etcd-client installed successfully!"

# Step 10: Restore ETCD snapshot with retries
restore_etcd_snapshot() {
    echo "Restoring ETCD snapshot..."
    docker exec -it "$masterContainerID" /bin/bash -c "
        rm -rf /var/lib/etcd || true
        ETCDCTL_API=3 etcdctl --data-dir /var/lib/etcd  --name mycluster-control-plane \
           --endpoints=https://127.0.0.1:2379 \
           --cacert=/etc/kubernetes/pki/etcd/ca.crt \
           --cert=/etc/kubernetes/pki/etcd/server.crt \
           --key=/etc/kubernetes/pki/etcd/server.key \
           --initial-cluster=mycluster-control-plane=$ETCD_URL \
           --initial-cluster-token mycluster-control-plane \
           --initial-advertise-peer-urls=$ETCD_URL \
           snapshot restore /etcd.db
    "
}

RETRY_LIMIT=3
RETRY_COUNT=0
while true; do
    if restore_etcd_snapshot; then
        echo "ETCD snapshot restored successfully!"
        break
    else
        echo "Error: Failed to restore snapshot. Cleaning up /var/lib/etcd and retrying..."
        docker exec -it "$masterContainerID" bash -c "rm -rf /var/lib/etcd"
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ "$RETRY_COUNT" -ge "$RETRY_LIMIT" ]; then
            echo "Error: Reached maximum retry attempts ($RETRY_LIMIT). Exiting."
            exit 1
        fi
        echo "Retrying snapshot restoration... Attempt $((RETRY_COUNT + 1)) of $RETRY_LIMIT..."
    fi
done

# Step 11: Stop the etcd container to recreate automatically
echo "Stopping the etcd container so it gets recreated automatically..."
docker exec -it "$masterContainerID" /bin/bash -c "
    crictl ps | grep etcd | awk '{print \$1}' | xargs -I{} crictl stop {}
"
echo "Waiting for the etcd container to restart..."
sleep 10
echo "Ensuring the etcd container is running..."
docker exec -it "$masterContainerID" /bin/bash -c "
    crictl ps | grep etcd
    if [ \$? -ne 0 ]; then
        echo 'Error: etcd container did not restart successfully.'
        exit 1
    fi
"

# Step 12: Verify the etcd restoration
echo "Verifying that ETCD has been restored correctly..."
kubectl get nodes
if [ $? -eq 0 ]; then
    echo "ETCD has been restored successfully, and the cluster is back online."
else
    echo "Failed to verify ETCD restoration. Please troubleshoot."
fi
