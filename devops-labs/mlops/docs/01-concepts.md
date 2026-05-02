# MLOps Core Concepts

## The ML Lifecycle

```
┌─────────────────────────────────────────────────────────────┐
│                     ML Lifecycle                             │
│                                                              │
│  Data → Feature    → Train  → Evaluate → Register → Serve   │
│  Eng   Engineering    Model     Model     Model      Model   │
│   │         │           │         │          │         │     │
│   ▼         ▼           ▼         ▼          ▼         ▼     │
│  Data    Feature     Training  Metrics   MLflow/    REST/    │
│  Pipeline  Store     Pipeline  Gate      Sagemaker  gRPC     │
│                                           Registry           │
│                            Monitoring (Data Drift, Perf)     │
│                            ↓ triggers retraining if needed   │
└─────────────────────────────────────────────────────────────┘
```

---

## Key Tools

| Tool | Purpose | Alternatives |
|------|---------|-------------|
| MLflow | Experiment tracking + model registry | W&B, Comet, Neptune |
| Kubeflow | ML pipelines on Kubernetes | Vertex AI, SageMaker |
| Feast | Feature store | Tecton, Hopsworks |
| BentoML | Model serving framework | Seldon, KServe, Triton |
| Great Expectations | Data validation | Pandera |
| Evidently AI | Model/data drift monitoring | Arize, WhyLabs |
| DVC | Data + model versioning | LakeFS |

---

## Experiment Tracking with MLflow

```python
import mlflow
import mlflow.sklearn
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, f1_score

# Set experiment
mlflow.set_experiment("fraud-detection-v2")

with mlflow.start_run(run_name="rf-baseline"):
    # Log parameters
    mlflow.log_params({
        "n_estimators": 100,
        "max_depth": 10,
        "min_samples_split": 5,
        "data_version": "v2024-01",
        "feature_set": "v3",
    })

    # Train
    model = RandomForestClassifier(n_estimators=100, max_depth=10)
    model.fit(X_train, y_train)
    predictions = model.predict(X_test)

    # Log metrics
    mlflow.log_metrics({
        "accuracy": accuracy_score(y_test, predictions),
        "f1_score": f1_score(y_test, predictions, average='weighted'),
        "train_samples": len(X_train),
    })

    # Log model with signature (input/output schema)
    from mlflow.models import infer_signature
    signature = infer_signature(X_train, model.predict(X_train))
    mlflow.sklearn.log_model(
        model,
        "model",
        signature=signature,
        registered_model_name="fraud-detector",  # Register in Model Registry
        input_example=X_train[:5]
    )

    # Log artifacts (feature importance, confusion matrix)
    mlflow.log_artifact("confusion_matrix.png")
    mlflow.log_artifact("feature_importance.csv")

    print(f"Run ID: {mlflow.active_run().info.run_id}")
```

---

## Model Registry Workflow

```python
from mlflow.tracking import MlflowClient

client = MlflowClient()

# 1. Get best run from experiment
best_run = client.search_runs(
    experiment_ids=["1"],
    filter_string="metrics.f1_score > 0.85",
    order_by=["metrics.f1_score DESC"],
    max_results=1
)[0]

# 2. Register model
model_uri = f"runs:/{best_run.info.run_id}/model"
registered = mlflow.register_model(model_uri, "fraud-detector")

# 3. Transition to staging
client.transition_model_version_stage(
    name="fraud-detector",
    version=registered.version,
    stage="Staging",
    archive_existing_versions=False
)

# 4. Run validation on staging model
model = mlflow.pyfunc.load_model(
    model_uri=f"models:/fraud-detector/Staging"
)
validation_score = evaluate_model(model, validation_set)

# 5. If passes threshold → promote to production
if validation_score > 0.87:
    client.transition_model_version_stage(
        name="fraud-detector",
        version=registered.version,
        stage="Production",
        archive_existing_versions=True  # Archive old production version
    )
```

---

## Data Drift Detection

```python
from evidently.metric_preset import DataDriftPreset, DataQualityPreset
from evidently.report import Report
import pandas as pd

# Reference data = training data
# Current data = data model is seeing in production

def detect_drift(reference_df: pd.DataFrame, current_df: pd.DataFrame) -> dict:
    report = Report(metrics=[
        DataDriftPreset(),      # Statistical drift per feature
        DataQualityPreset(),    # Missing values, outliers
    ])

    report.run(
        reference_data=reference_df,
        current_data=current_df
    )

    results = report.as_dict()
    drift_detected = results["metrics"][0]["result"]["dataset_drift"]

    # Log to MLflow
    with mlflow.start_run():
        mlflow.log_metric("drift_detected", int(drift_detected))
        mlflow.log_artifact("drift_report.html")

    return {
        "drift_detected": drift_detected,
        "drifted_features": [
            f for f, v in results["metrics"][0]["result"]["drift_by_columns"].items()
            if v["drift_detected"]
        ]
    }

# Schedule this check daily via Kubernetes CronJob
# If drift_detected → trigger retraining pipeline
```

---

## Model Serving with BentoML

```python
import bentoml
import numpy as np

# Save model to BentoML
bentoml.sklearn.save_model(
    "fraud_detector",
    model,
    signatures={"predict": {"batchable": True, "batch_dim": 0}},
    metadata={"accuracy": 0.94, "version": "v2024-01"},
)

# Create service
@bentoml.service(
    resources={"cpu": "2", "memory": "1Gi"},
    traffic={"timeout": 10}
)
class FraudDetector:
    model_ref = bentoml.models.get("fraud_detector:latest")

    def __init__(self):
        self.model = self.model_ref.load_model()

    @bentoml.api(batch=True, max_batch_size=100, max_latency_ms=100)
    def predict(self, features: np.ndarray) -> np.ndarray:
        return self.model.predict_proba(features)[:, 1]

    @bentoml.api
    def health(self) -> dict:
        return {"status": "healthy", "model": str(self.model_ref)}

# Build and containerize
# bentoml build .
# bentoml containerize fraud_detector_service:latest

# Deploy to K8s
# kubectl apply -f k8s/fraud-detector-deployment.yaml
```

---

## Feature Store Pattern

```python
from feast import FeatureStore, Entity, FeatureView, Field, FileSource
from feast.types import Float32, Int64

# Define entities (the object being predicted about)
user = Entity(
    name="user_id",
    join_keys=["user_id"],
    description="User ID"
)

# Define feature view (logical grouping of related features)
user_transaction_stats = FeatureView(
    name="user_transaction_stats",
    entities=[user],
    ttl=timedelta(days=7),  # Feature freshness TTL
    schema=[
        Field(name="avg_transaction_7d",  dtype=Float32),
        Field(name="num_transactions_7d", dtype=Int64),
        Field(name="max_transaction_7d",  dtype=Float32),
        Field(name="fraud_ratio_30d",     dtype=Float32),
    ],
    source=FileSource(path="data/user_stats.parquet"),
)

# Training: get historical features (point-in-time correct joins)
store = FeatureStore(repo_path=".")
training_df = store.get_historical_features(
    entity_df=pd.DataFrame({"user_id": users, "event_timestamp": timestamps}),
    features=["user_transaction_stats:avg_transaction_7d",
              "user_transaction_stats:fraud_ratio_30d"]
).to_df()

# Serving: get real-time features (< 10ms)
features = store.get_online_features(
    features=["user_transaction_stats:avg_transaction_7d"],
    entity_rows=[{"user_id": "user_123"}]
).to_dict()
```

---

## CI/CD for ML Pipeline (GitHub Actions)

```yaml
# .github/workflows/mlops.yml
name: MLOps Pipeline

on:
  schedule:
  - cron: '0 2 * * *'   # Nightly retraining
  push:
    paths: ['src/model/**', 'data/features/**']

jobs:
  train-and-validate:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4

    - name: Run training pipeline
      run: python src/train.py --experiment $GITHUB_SHA
      env:
        MLFLOW_TRACKING_URI: ${{ secrets.MLFLOW_URI }}

    - name: Run data quality checks
      run: python src/validate_data.py

    - name: Evaluate model
      id: eval
      run: |
        python src/evaluate.py
        echo "f1_score=$(cat metrics.json | jq .f1_score)" >> $GITHUB_OUTPUT

    - name: Promote if above threshold
      if: ${{ steps.eval.outputs.f1_score > 0.85 }}
      run: python src/promote_model.py --stage production

    - name: Deploy updated model
      if: ${{ steps.eval.outputs.f1_score > 0.85 }}
      run: |
        kubectl rollout restart deployment/fraud-detector -n production
        kubectl rollout status deployment/fraud-detector -n production
```
