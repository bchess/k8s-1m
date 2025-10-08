KWOK_REPO=kubernetes-sigs/kwok
KWOK_LATEST_RELEASE=$(curl "https://api.github.com/repos/${KWOK_REPO}/releases/latest" | jq -r '.tag_name')
kubectl apply -f "https://github.com/${KWOK_REPO}/releases/download/${KWOK_LATEST_RELEASE}/kwok.yaml"
kubectl apply -f "https://github.com/${KWOK_REPO}/releases/download/${KWOK_LATEST_RELEASE}/stage-fast.yaml"

# rename service port to metrics for scraping
kubectl -n kube-system patch svc kwok-controller --type=json -p='[{"op": "replace", "path": "/spec/ports/0/name", "value": "metrics"}]'

# Disable the default deployment controller and make our statefulset
kubectl scale -n kube-system --replicas 0 deployment/kwok-controller
kubectl apply -f kwok-controller.yaml

