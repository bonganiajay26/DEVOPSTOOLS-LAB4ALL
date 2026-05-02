# MLOps Interview Questions

## Q1. What is MLOps and how is it different from DevOps?

```
DevOps: automates software delivery pipeline
         code → test → build → deploy

MLOps: automates ML model lifecycle
         data → feature engineering → train → validate → deploy → monitor → retrain

Key differences:
1. Data is a first-class citizen (code changes rarely, data changes constantly)
2. Models degrade silently (no exception thrown when model makes bad predictions)
3. Reproducibility is harder (same code + same data + same env = same model)
4. Multiple artifacts: code, model, data, features — all need versioning
5. Experimentation is core: ML teams run hundreds of experiments
```

---

## Q2. Explain the difference between data drift and model drift (concept drift).

```python
# Data drift: distribution of INPUT features changes
# Example: user age distribution shifts (COVID changed behavior)
# Detection: statistical tests (KS-test, PSI, Jensen-Shannon divergence)
from scipy.stats import ks_2samp
stat, p_value = ks_2samp(reference_data['age'], current_data['age'])
if p_value < 0.05:
    print("Significant drift in 'age' feature!")

# Model drift (concept drift): relationship between input and output changes
# Example: fraud patterns change (attackers adapt)
# Detection: monitor prediction accuracy on labeled samples
# OR: compare predictions on fixed test set over time

# Pipeline:
# 1. Log all predictions + timestamps
# 2. Periodically label samples (human review or delayed labels)
# 3. Compute accuracy on recent labeled data
# 4. Alert if drops below threshold → trigger retraining

# PSI (Population Stability Index):
# PSI < 0.1: no drift
# PSI 0.1-0.2: moderate drift (investigate)
# PSI > 0.2: significant drift (retrain)
```

---

## Q3. How do you ensure reproducibility in ML experiments?

```python
# 1. Pin all dependencies
pip freeze > requirements.txt
conda env export > environment.yml

# 2. Set all random seeds
import random, numpy as np, torch
random.seed(42)
np.random.seed(42)
torch.manual_seed(42)

# 3. Version your data (DVC)
dvc add data/training.parquet
git add data/training.parquet.dvc .gitignore
git commit -m "Add training data v1"

# 4. Log everything to MLflow
with mlflow.start_run():
    mlflow.log_params({"data_hash": hashlib.md5(open(data_path,'rb').read()).hexdigest()})
    mlflow.log_params(config)
    mlflow.set_tag("git_commit", subprocess.check_output(['git','rev-parse','HEAD']).decode().strip())

# 5. Use Docker for environment reproducibility
FROM python:3.12-slim
COPY requirements.txt .
RUN pip install -r requirements.txt
# Training runs inside container = same environment always
```

---

## Q4. How do you serve ML models at scale in Kubernetes?

```yaml
# KServe (formerly KFServing) — model serving framework on K8s
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: fraud-detector
  namespace: production
spec:
  predictor:
    sklearn:
      storageUri: s3://my-models/fraud-detector/v3/
      resources:
        requests:
          cpu: 500m
          memory: 1Gi
        limits:
          cpu: 2000m
          memory: 4Gi
    minReplicas: 2
    maxReplicas: 20
    scaleMetric: rps
    scaleTarget: 100    # Scale out when > 100 req/s per pod

  # A/B testing: 90% to v3, 10% to v4 (canary)
  # canaryTrafficPercent: 10

# Access:
# curl -X POST https://fraud-detector.production.svc.cluster.local/v1/models/fraud-detector:predict \
#   -d '{"instances": [[1.5, 0.2, ...]]}'
```

---

## Q5. What is a feature store and why do you need one?

```
Problem without feature store:
  Team A computes "avg_spend_7d" one way
  Team B computes "avg_spend_7d" slightly differently
  Model A and Model B get different features for same user
  → Inconsistency, bugs, offline/online skew

Feature store solves:
  1. Single feature computation (write once, use many)
  2. Point-in-time correctness (no data leakage in training)
  3. Online/offline consistency (same features in training AND serving)
  4. Feature reuse (100 models can use same "user_risk_score" feature)
  5. Freshness management (TTL per feature)

Architecture:
  Batch pipeline → Offline store (BigQuery/Redshift) → Training
  Streaming pipeline → Online store (Redis/DynamoDB) → Inference (< 10ms)
```

---

## Q6. How do you implement model A/B testing?

```python
# Option 1: Traffic-split in K8s (KServe/Istio)
# 90% requests → model-v1, 10% → model-v2

# Option 2: Application-level assignment
import hashlib

def get_model_version(user_id: str) -> str:
    # Deterministic assignment (same user always gets same model)
    bucket = int(hashlib.md5(user_id.encode()).hexdigest(), 16) % 100
    if bucket < 10:   # 10% in treatment
        return "v2"
    return "v1"

# Log both versions' predictions
def predict(user_id: str, features: dict) -> float:
    model_version = get_model_version(user_id)
    model = load_model(model_version)
    prediction = model.predict(features)

    # Log to analytics platform
    log_event({
        "user_id": user_id,
        "model_version": model_version,
        "prediction": prediction,
        "timestamp": datetime.utcnow().isoformat()
    })

    return prediction

# Analysis: compare business metrics (conversion, revenue) by group
# Statistical significance test (chi-square, t-test) before concluding
```

---

## Q7. How do you handle model versioning?

```
Three types of versions to track:
  Code version: git SHA
  Data version: DVC hash or timestamp (2024-01-15)
  Model version: MLflow version number or semver

Model Registry stages:
  Development → Staging → Production → Archived

Version naming convention:
  model-name/vMAJOR.MINOR
  fraud-detector/v2.3
  MAJOR: architectural change (new features, different algorithm)
  MINOR: retrained on new data, same architecture

In MLflow:
  Model version 1 = trained on data_2024_01 with code_abc123
  Model version 2 = trained on data_2024_02 with code_abc123 (new data)
  Model version 3 = trained on data_2024_02 with code_def456 (new algorithm)
```

---

## Q8. What is the train-serve skew problem?

```python
# Problem: features computed differently in training vs serving
# Often the most common ML bug

# TRAINING (using pandas, full dataset):
training_features = df.groupby('user_id')['amount'].mean()
# Computes mean including FUTURE transactions (data leakage!)

# SERVING (real-time, single transaction):
features = redis.get(f"user:{user_id}:avg_amount")
# Uses precomputed rolling average from last 7 days

# Different computation → different distributions → model underperforms in prod

# Solution: Feature Store with point-in-time correctness
# Training: "give me this user's features AS OF this transaction date"
features = store.get_historical_features(
    entity_df=pd.DataFrame({
        "user_id": [user_id],
        "event_timestamp": [transaction_timestamp]  # point-in-time!
    }),
    features=["user_stats:avg_amount_7d"]
)

# Serving: same feature computation logic as training
features = store.get_online_features(
    features=["user_stats:avg_amount_7d"],
    entity_rows=[{"user_id": user_id}]
)

# Prevention:
# 1. Use feature store for all features
# 2. Shadow mode: log serving features, compare to training distribution
# 3. Use same code path (Python class) for both training and serving
```

---

## Q9. How do you handle large model deployments (LLMs) in K8s?

```yaml
# LLM serving with GPUs
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-server
spec:
  replicas: 2
  template:
    spec:
      nodeSelector:
        accelerator: nvidia-tesla-a100
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule

      containers:
      - name: vllm-server
        image: vllm/vllm-openai:latest
        args:
        - --model
        - mistralai/Mistral-7B-Instruct-v0.2
        - --tensor-parallel-size
        - "2"       # Split model across 2 GPUs
        - --max-model-len
        - "8192"
        - --port
        - "8000"
        resources:
          limits:
            nvidia.com/gpu: 2
            memory: 40Gi
          requests:
            memory: 32Gi
        env:
        - name: HUGGING_FACE_HUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-credentials
              key: token

# Model caching: download once to PVC
# Share PVC across replicas (ReadOnlyMany)
      volumes:
      - name: model-cache
        persistentVolumeClaim:
          claimName: model-weights-pvc
          readOnly: true
```

---

## Q10. What metrics do you monitor for a production ML model?

```python
# Operational metrics (DevOps concerns):
operational_metrics = {
    "prediction_latency_p99": "< 100ms",
    "throughput_rps": "current load",
    "error_rate": "< 0.1%",
    "cpu_usage": "resource efficiency",
    "memory_usage": "OOM prevention",
    "model_load_time": "cold start",
}

# ML-specific metrics (model health):
ml_metrics = {
    # Input monitoring
    "feature_drift_psi": "< 0.1 per feature",
    "missing_feature_rate": "< 0.5%",
    "prediction_distribution": "histogram of scores",

    # Output monitoring
    "prediction_drift": "compare score distribution to baseline",
    "confidence_score_avg": "low confidence = poor predictions",

    # Business metrics (delayed feedback)
    "accuracy_on_labeled_sample": "weekly spot check",
    "false_positive_rate": "business cost",
    "false_negative_rate": "missed fraud",
}

# Dashboard: Grafana + Prometheus
# Log predictions to BigQuery/S3 → query for analysis
# Send metrics to Prometheus from model server
```

---

## Q11. How do you manage ML pipelines with Kubeflow?

```python
# Kubeflow Pipelines — ML workflows as K8s-native DAGs

from kfp import dsl, compiler
from kfp.dsl import component

@component(base_image="python:3.12-slim", packages_to_install=["scikit-learn"])
def train_model(data_path: str, model_output: dsl.Output[dsl.Model]):
    import pickle, sklearn
    # ... training code ...
    with open(model_output.path, 'wb') as f:
        pickle.dump(model, f)

@component(base_image="python:3.12-slim")
def evaluate_model(
    model: dsl.Input[dsl.Model],
    test_data: str
) -> float:
    # ... evaluation code ...
    return f1_score

@component
def deploy_model(model: dsl.Input[dsl.Model], f1_score: float):
    if f1_score > 0.85:
        # Deploy to KServe
        pass

@dsl.pipeline(name="fraud-detection-pipeline")
def fraud_pipeline(data_version: str = "latest"):
    train_task = train_model(data_path=f"gs://my-bucket/data/{data_version}")
    eval_task = evaluate_model(
        model=train_task.outputs['model_output'],
        test_data=f"gs://my-bucket/test/{data_version}"
    )
    deploy_task = deploy_model(
        model=train_task.outputs['model_output'],
        f1_score=eval_task.output
    )

# Compile and submit
compiler.Compiler().compile(fraud_pipeline, 'pipeline.yaml')
# Submit via UI or: kfp.Client().create_run_from_pipeline_package('pipeline.yaml')
```

---

## Q12. What is shadow mode deployment for ML models?

```python
# Shadow mode: new model runs alongside production model
# New model's predictions logged but NOT served to users
# Compare outputs: if new model would have been better → promote

# Implementation:
def predict_with_shadow(features: dict, user_id: str) -> float:
    # Primary model serves the user
    primary_prediction = primary_model.predict(features)

    # Shadow model runs asynchronously (don't block on it)
    import asyncio
    asyncio.create_task(
        log_shadow_prediction(shadow_model, features, primary_prediction)
    )

    return primary_prediction

async def log_shadow_prediction(shadow_model, features, primary_pred):
    shadow_pred = shadow_model.predict(features)
    # Log to analytics: shadow vs primary
    await analytics.log({
        "primary": primary_pred,
        "shadow": shadow_pred,
        "agreement": abs(primary_pred - shadow_pred) < 0.1
    })

# After 1 week of shadow mode:
# Query analytics: where did shadow model differ from primary?
# On the subset where labels are available: which was more accurate?
# If shadow is better → promote shadow to primary
```

---

## Q13. How do you handle imbalanced datasets and class imbalance in production?

```python
# Training: handle imbalance
from sklearn.utils import class_weight
from imblearn.over_sampling import SMOTE

# Class weights (penalize wrong predictions on minority class)
weights = class_weight.compute_class_weight(
    'balanced', classes=np.unique(y_train), y=y_train
)
model = RandomForestClassifier(class_weight={0: weights[0], 1: weights[1]})

# SMOTE (synthetic oversampling)
sm = SMOTE(random_state=42, sampling_strategy=0.3)  # 30% minority
X_resampled, y_resampled = sm.fit_resample(X_train, y_train)

# Production: monitor class distribution in predictions
# If model starts predicting all 0s → drift or bug

# Track:
# precision_at_k (top K most suspicious → how many are actually fraud?)
# recall_at_k (of all frauds, how many are in top K predictions?)
# AUC-PR (better than AUC-ROC for imbalanced)
```

---

## Q14. What is LLMOps? How is it different from MLOps?

```
MLOps focuses on:
  - Traditional ML: train/evaluate/deploy tabular or vision models
  - Custom training loops, model artifacts
  - Metrics: accuracy, F1, RMSE

LLMOps adds:
  - Prompt engineering (new "code" that changes behavior)
  - Fine-tuning (LoRA, QLoRA for cost-efficient customization)
  - RAG (Retrieval Augmented Generation) with vector databases
  - Evaluation without ground truth (LLM-as-judge, human eval)
  - Prompt versioning and A/B testing
  - Token cost optimization
  - Guardrails (content moderation, jailbreak prevention)
  - Context management (conversation history, context window)

LLMOps stack:
  LangChain/LlamaIndex → RAG pipelines
  Langfuse/LangSmith  → LLM observability (trace prompts)
  Chroma/Pinecone     → Vector database for RAG
  Weights & Biases    → Experiment tracking for fine-tuning
  vLLM/Ollama         → Model serving
  
Prompt versioning:
  Use Git + prompt templates
  A/B test prompts like code changes
  Log prompt hash + version with every inference
```

---

## Q15. How do you implement continuous training with data validation gates?

```python
# Data validation before training (Great Expectations)
import great_expectations as ge

def validate_training_data(df: pd.DataFrame) -> bool:
    ge_df = ge.from_pandas(df)

    validation_result = ge_df.expect_suite(
        expectations=[
            # Schema expectations
            ge_df.expect_column_to_exist("user_id"),
            ge_df.expect_column_to_exist("transaction_amount"),
            ge_df.expect_column_values_to_be_of_type("transaction_amount", "float"),

            # Value expectations
            ge_df.expect_column_values_to_be_between("transaction_amount", 0, 1000000),
            ge_df.expect_column_values_to_not_be_null("user_id"),

            # Distribution expectations
            ge_df.expect_column_mean_to_be_between("transaction_amount", 50, 500),
            ge_df.expect_column_proportion_of_unique_values_to_be_between("user_id", 0.001, 1.0),

            # Label distribution (prevent label leakage)
            ge_df.expect_column_proportion_of_unique_values_to_be_between(
                "is_fraud", 0.001, 0.05  # Expect 0.1-5% fraud rate
            ),
        ]
    )

    if not validation_result.success:
        # Log failures
        mlflow.log_dict(validation_result.to_json_dict(), "data_validation_failures.json")
        raise ValueError("Training data failed validation!")

    return True

# Continuous training pipeline (runs nightly):
# 1. Fetch new data
# 2. validate_training_data(new_data) ← gate
# 3. Check for drift (PSI check)
# 4. If drift > threshold OR scheduled weekly: retrain
# 5. validate_model(new_model) ← gate (accuracy > threshold)
# 6. Compare to production model (challenger vs champion)
# 7. If better: deploy
```
