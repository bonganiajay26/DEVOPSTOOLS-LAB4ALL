# Lab 01: MLflow — Experiment Tracking and Model Registry

**Difficulty**: Intermediate | **Time**: 60 minutes  
**Goal**: Track ML experiments, register the best model, and serve it as an API.

---

## Part 1: Setup MLflow

```bash
mkdir mlflow-lab && cd mlflow-lab

pip install mlflow scikit-learn pandas numpy flask

# Start MLflow tracking server with local storage
mlflow server \
  --backend-store-uri sqlite:///mlflow.db \
  --default-artifact-root ./mlruns \
  --host 0.0.0.0 \
  --port 5000 &

# Open: http://localhost:5000
```

---

## Part 2: Train Models with Tracking

```python
# train.py
import mlflow
import mlflow.sklearn
import pandas as pd
import numpy as np
from sklearn.model_selection import train_test_split, cross_val_score
from sklearn.ensemble import RandomForestClassifier, GradientBoostingClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score, f1_score, roc_auc_score
from sklearn.datasets import make_classification
from sklearn.preprocessing import StandardScaler
import warnings
warnings.filterwarnings('ignore')

# Configure MLflow
mlflow.set_tracking_uri("http://localhost:5000")
mlflow.set_experiment("fraud-detection-v1")

# Generate synthetic fraud dataset
X, y = make_classification(
    n_samples=10000,
    n_features=20,
    n_informative=10,
    n_classes=2,
    weights=[0.95, 0.05],  # 5% fraud rate (imbalanced)
    random_state=42
)
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

# Scale features
scaler = StandardScaler()
X_train_scaled = scaler.fit_transform(X_train)
X_test_scaled = scaler.transform(X_test)

def train_and_log(model, model_name, params):
    """Train a model and log everything to MLflow."""
    with mlflow.start_run(run_name=model_name):
        # Log parameters
        mlflow.log_params(params)
        mlflow.log_param("dataset_size", len(X_train))
        mlflow.log_param("features", X_train.shape[1])
        mlflow.log_param("train_fraud_rate", y_train.mean())

        # Train
        model.fit(X_train_scaled, y_train)
        predictions = model.predict(X_test_scaled)
        proba = model.predict_proba(X_test_scaled)[:, 1]

        # Calculate metrics
        metrics = {
            "accuracy":  accuracy_score(y_test, predictions),
            "f1_score":  f1_score(y_test, predictions),
            "auc_roc":   roc_auc_score(y_test, proba),
            "cv_f1_mean": cross_val_score(model, X_train_scaled, y_train,
                                           cv=5, scoring='f1').mean()
        }

        # Log metrics
        mlflow.log_metrics(metrics)

        # Log the model with signature
        from mlflow.models.signature import infer_signature
        signature = infer_signature(X_train_scaled, predictions)

        mlflow.sklearn.log_model(
            model,
            "model",
            registered_model_name=f"fraud-detector-{model_name.lower()}",
            signature=signature,
            input_example=X_test_scaled[:5]
        )

        # Log feature importance (for tree models)
        if hasattr(model, 'feature_importances_'):
            import json
            importance = dict(enumerate(model.feature_importances_.tolist()))
            mlflow.log_dict(importance, "feature_importance.json")

        print(f"✅ {model_name}: F1={metrics['f1_score']:.3f}, AUC={metrics['auc_roc']:.3f}")
        return mlflow.active_run().info.run_id, metrics

# Experiment 1: Random Forest
rf_run_id, rf_metrics = train_and_log(
    RandomForestClassifier(n_estimators=100, max_depth=10, random_state=42),
    "RandomForest",
    {"n_estimators": 100, "max_depth": 10, "model_type": "RandomForest"}
)

# Experiment 2: Gradient Boosting
gb_run_id, gb_metrics = train_and_log(
    GradientBoostingClassifier(n_estimators=100, learning_rate=0.1, random_state=42),
    "GradientBoosting",
    {"n_estimators": 100, "learning_rate": 0.1, "model_type": "GradientBoosting"}
)

# Experiment 3: Logistic Regression (baseline)
lr_run_id, lr_metrics = train_and_log(
    LogisticRegression(C=1.0, max_iter=1000, random_state=42),
    "LogisticRegression",
    {"C": 1.0, "max_iter": 1000, "model_type": "LogisticRegression"}
)

print("\n=== Experiment Results ===")
print(f"RandomForest:     F1={rf_metrics['f1_score']:.3f}")
print(f"GradientBoosting: F1={gb_metrics['f1_score']:.3f}")
print(f"LogisticRegression: F1={lr_metrics['f1_score']:.3f}")
```

```bash
python train.py
# View results at http://localhost:5000
```

---

## Part 3: Model Registry — Promote Best Model

```python
# promote_model.py
import mlflow
from mlflow.tracking import MlflowClient

mlflow.set_tracking_uri("http://localhost:5000")
client = MlflowClient()

# Find best run by F1 score
best_run = client.search_runs(
    experiment_ids=["1"],
    filter_string="metrics.f1_score > 0.7",
    order_by=["metrics.f1_score DESC"],
    max_results=1
)[0]

print(f"Best model: Run ID={best_run.info.run_id}")
print(f"F1 Score:   {best_run.data.metrics['f1_score']:.3f}")
print(f"AUC-ROC:    {best_run.data.metrics['auc_roc']:.3f}")
print(f"Model type: {best_run.data.params['model_type']}")

# Register model in registry
model_name = "fraud-detector-production"
model_uri = f"runs:/{best_run.info.run_id}/model"

registered = mlflow.register_model(model_uri, model_name)
print(f"\n✅ Registered as: {model_name} v{registered.version}")

# Transition to staging first
client.transition_model_version_stage(
    name=model_name,
    version=registered.version,
    stage="Staging",
    archive_existing_versions=False
)
print(f"📋 Moved to Staging")

# Validate on held-out test set
# (In real workflow: run integration tests, A/B test, etc.)
import time
print("Running validation tests...")
time.sleep(2)   # Simulate validation

# Promote to Production
client.transition_model_version_stage(
    name=model_name,
    version=registered.version,
    stage="Production",
    archive_existing_versions=True    # Archive old production version
)
print(f"🚀 Promoted to Production!")

# Add description
client.update_model_version(
    name=model_name,
    version=registered.version,
    description=f"Best model from experiment fraud-detection-v1. "
                f"F1={best_run.data.metrics['f1_score']:.3f}"
)
```

```bash
python promote_model.py
```

---

## Part 4: Serve the Model

```bash
# Option 1: MLflow built-in serving
mlflow models serve \
  -m "models:/fraud-detector-production/Production" \
  -p 8080 \
  --no-conda &

# Test the REST API
curl -X POST http://localhost:8080/invocations \
  -H "Content-Type: application/json" \
  -d '{
    "inputs": [[0.5, -1.2, 0.8, 1.3, -0.2, 0.7, -0.5, 1.1, 0.3, -0.8,
                 0.9, -1.4, 0.6, 0.2, -0.3, 1.5, -0.7, 0.4, -1.1, 0.9]]
  }'
# Response: {"predictions": [0]}   (0 = not fraud, 1 = fraud)

# Option 2: Docker container
mlflow models build-docker \
  -m "models:/fraud-detector-production/Production" \
  -n fraud-detector:latest

docker run -p 8080:8080 fraud-detector:latest
```

---

## Part 5: Automated Retraining Pipeline

```python
# retrain_pipeline.py
# Simulates a weekly retraining pipeline

import mlflow
import mlflow.sklearn
from datetime import datetime
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.datasets import make_classification
from sklearn.model_selection import train_test_split
from sklearn.metrics import f1_score

mlflow.set_tracking_uri("http://localhost:5000")
mlflow.set_experiment("fraud-detection-weekly-retrain")

MODEL_NAME = "fraud-detector-production"
MIN_F1_THRESHOLD = 0.70   # Must beat this to deploy

def retrain():
    """Retrain with fresh data and deploy if better than current."""
    timestamp = datetime.utcnow().strftime("%Y-%m-%d")
    
    with mlflow.start_run(run_name=f"retrain-{timestamp}"):
        # Simulate fresh data
        X, y = make_classification(n_samples=12000, n_features=20,
                                    n_informative=10, weights=[0.95, 0.05],
                                    random_state=int(datetime.now().timestamp()))
        X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2)

        model = GradientBoostingClassifier(n_estimators=100, learning_rate=0.1)
        model.fit(X_train, y_train)
        
        f1 = f1_score(y_test, model.predict(X_test))
        mlflow.log_metric("f1_score", f1)
        mlflow.log_param("retrain_date", timestamp)

        if f1 < MIN_F1_THRESHOLD:
            print(f"❌ Model F1={f1:.3f} below threshold {MIN_F1_THRESHOLD}. Not deploying.")
            return

        # Register new version
        registered = mlflow.sklearn.log_model(
            model, "model",
            registered_model_name=MODEL_NAME
        )
        
        print(f"✅ New model version {registered.registered_model.latest_versions[-1].version}")
        print(f"   F1={f1:.3f}. Promoting to Production...")
        
        # Auto-promote
        client = mlflow.tracking.MlflowClient()
        client.transition_model_version_stage(
            name=MODEL_NAME,
            version=registered.registered_model.latest_versions[-1].version,
            stage="Production",
            archive_existing_versions=True
        )

retrain()
```

---

## Cleanup

```bash
# Kill MLflow server
pkill -f "mlflow server"

cd ..
rm -rf mlflow-lab
```

## What You Learned

- [x] MLflow experiment tracking (params, metrics, artifacts)
- [x] Comparing runs and finding the best model
- [x] Model Registry: stages (Staging → Production)
- [x] Serving models with MLflow built-in server
- [x] Automated retraining with quality gates
