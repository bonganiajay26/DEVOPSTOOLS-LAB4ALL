# Lab 02: Model Serving with KServe on Kubernetes

**Difficulty**: Advanced | **Time**: 60 minutes  
**Goal**: Deploy a trained ML model as a REST API using KServe InferenceService on Kubernetes.

---

## Architecture

```
Client → KServe InferenceService
              │
         ┌────┴────┐
         │  Model  │  (sklearn, TF, PyTorch, ONNX, MLflow)
         │ Server  │
         └────┬────┘
              │
       ┌──────┴───────┐
   Transformer    Explainer    (optional)
   (pre/post     (SHAP/LIME
    processing)   explanations)
```

---

## Part 1: Install KServe

```bash
kind create cluster --name kserve-lab

# Install cert-manager (required by KServe)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cert-manager -n cert-manager --timeout=120s

# Install KServe (Kubernetes-native mode, no Knative needed)
kubectl apply -f https://github.com/kserve/kserve/releases/download/v0.11.2/kserve.yaml
kubectl apply -f https://github.com/kserve/kserve/releases/download/v0.11.2/kserve-runtimes.yaml

# Verify
kubectl get pods -n kserve
```

---

## Part 2: Train and Save a Model

```python
# train_and_save.py
import pickle
import numpy as np
from sklearn.datasets import load_iris
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import accuracy_score
import os

# Load and train
X, y = load_iris(return_X_y=True)
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

model = GradientBoostingClassifier(n_estimators=100, random_state=42)
model.fit(X_train, y_train)

predictions = model.predict(X_test)
print(f"Accuracy: {accuracy_score(y_test, predictions):.3f}")

# Save model in KServe's expected format: model.pkl in /model-store/
os.makedirs("model-store", exist_ok=True)
with open("model-store/model.pkl", "wb") as f:
    pickle.dump(model, f)

print("Model saved to model-store/model.pkl")

# Also save feature names for documentation
import json
feature_info = {
    "features": ["sepal_length", "sepal_width", "petal_length", "petal_width"],
    "classes": ["setosa", "versicolor", "virginica"]
}
with open("model-store/feature_info.json", "w") as f:
    json.dump(feature_info, f)
```

```bash
python train_and_save.py

# Upload to MinIO (local S3) for KServe to pull
# Install MinIO
kubectl apply -f https://github.com/minio/minio/blob/master/docs/orchestration/kubernetes/minio-standalone.yaml

# Or use local storage with a PVC
```

---

## Part 3: Deploy with InferenceService

```bash
# Create namespace
kubectl create namespace mlops

# Create S3 credentials (or use MinIO)
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: s3-credentials
  namespace: mlops
  annotations:
    serving.kserve.io/s3-endpoint: minio.minio-operator.svc.cluster.local:9000
    serving.kserve.io/s3-usehttps: "0"
    serving.kserve.io/s3-region: us-east-1
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: minioadmin
  AWS_SECRET_ACCESS_KEY: minioadmin
EOF

# Deploy the InferenceService
cat << 'EOF' | kubectl apply -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: iris-classifier
  namespace: mlops
  annotations:
    sidecar.istio.io/inject: "false"   # Disable Istio for this lab
spec:
  predictor:
    serviceAccountName: kserve-sa

    sklearn:
      protocolVersion: v2
      storageUri: pvc://iris-model-pvc/model-store
      resources:
        requests:
          cpu: 200m
          memory: 256Mi
        limits:
          cpu: 1000m
          memory: 512Mi

    minReplicas: 1
    maxReplicas: 5

    # Scale based on requests per second
    scaleTarget: 10
    scaleMetric: rps
EOF

kubectl get inferenceservice -n mlops
kubectl describe inferenceservice iris-classifier -n mlops
```

---

## Part 4: Make Predictions

```bash
# Wait for model to be ready
kubectl wait --for=condition=ready inferenceservice/iris-classifier \
  -n mlops --timeout=120s

# Port-forward the service
kubectl port-forward svc/iris-classifier-predictor-default 8080:80 -n mlops &

# Single prediction (V1 protocol)
curl -X POST http://localhost:8080/v1/models/iris-classifier:predict \
  -H "Content-Type: application/json" \
  -d '{
    "instances": [
      [5.1, 3.5, 1.4, 0.2],
      [6.2, 3.4, 5.4, 2.3]
    ]
  }'
# Response: {"predictions": [0, 2]}  (0=setosa, 2=virginica)

# V2 protocol (OpenInference standard)
curl -X POST http://localhost:8080/v2/models/iris-classifier/infer \
  -H "Content-Type: application/json" \
  -d '{
    "inputs": [{
      "name": "input-0",
      "shape": [2, 4],
      "datatype": "FP64",
      "data": [
        [5.1, 3.5, 1.4, 0.2],
        [6.2, 3.4, 5.4, 2.3]
      ]
    }]
  }'

# Get model metadata
curl http://localhost:8080/v2/models/iris-classifier
```

---

## Part 5: A/B Testing with Traffic Split

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: iris-ab-test
  namespace: mlops
spec:
  predictor:
    # 90% traffic to stable model
    canaryTrafficPercent: 10    # 10% to canary

  # Canary configuration
  canary:
    sklearn:
      storageUri: pvc://iris-model-v2-pvc/model-store
EOF

# Gradually shift traffic
kubectl patch inferenceservice iris-ab-test -n mlops \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/predictor/canaryTrafficPercent","value":50}]'

# After validation, promote canary to 100%
kubectl patch inferenceservice iris-ab-test -n mlops \
  --type='json' \
  -p='[{"op":"remove","path":"/spec/canary"},
       {"op":"remove","path":"/spec/predictor/canaryTrafficPercent"}]'
```

---

## Part 6: Add Monitoring

```bash
# Install Prometheus + Grafana
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace

# KServe exposes Prometheus metrics at :8080/metrics
# Create ServiceMonitor
cat << 'EOF' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kserve-metrics
  namespace: monitoring
spec:
  selector:
    matchLabels:
      serving.kserve.io/inferenceservice: iris-classifier
  endpoints:
  - port: http
    path: /metrics
    interval: 15s
  namespaceSelector:
    matchNames:
    - mlops
EOF

# Useful KServe metrics in Prometheus:
# revision_request_count             → total requests per model
# revision_request_latencies_bucket  → latency histograms
# request_duration_milliseconds      → inference time
```

---

## Cleanup

```bash
kubectl delete inferenceservice iris-classifier -n mlops
kind delete cluster --name kserve-lab
```

## What You Learned

- [x] Installing KServe on Kubernetes
- [x] Training and saving a scikit-learn model
- [x] Deploying a model as an InferenceService
- [x] V1 and V2 prediction protocol
- [x] A/B testing with canary traffic split
- [x] Monitoring inference metrics with Prometheus
