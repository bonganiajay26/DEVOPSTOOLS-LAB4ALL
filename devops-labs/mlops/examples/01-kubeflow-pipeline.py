# Example 01: Kubeflow Pipeline — End-to-End ML Pipeline on Kubernetes
# Defines a full ML pipeline: data validation → training → evaluation → deploy

from kfp import dsl, compiler
from kfp.dsl import component, Dataset, Model, Metrics, Input, Output
from typing import NamedTuple


# ── Component 1: Data Validation ─────────────────────────────
@component(
    base_image="python:3.12-slim",
    packages_to_install=["pandas==2.0.3", "great-expectations==0.18.0"]
)
def validate_data(
    data_uri: str,
    output_report: Output[Dataset]
) -> NamedTuple("ValidationResult", [("passed", bool), ("row_count", int)]):
    """Validate incoming data meets quality standards."""
    import pandas as pd
    import json

    df = pd.read_parquet(data_uri)
    print(f"Loaded {len(df)} rows, {len(df.columns)} columns")

    # Quality checks
    checks = {
        "no_nulls_in_target":   df["label"].notna().all(),
        "min_rows":             len(df) >= 1000,
        "feature_range":        (df["amount"] >= 0).all(),
        "no_duplicate_ids":     df["transaction_id"].nunique() == len(df),
        "fraud_rate_reasonable": 0.001 <= df["label"].mean() <= 0.20
    }

    passed = all(checks.values())
    failed_checks = [k for k, v in checks.items() if not v]

    # Save validation report
    report = {
        "passed": passed,
        "row_count": len(df),
        "column_count": len(df.columns),
        "checks": checks,
        "failed_checks": failed_checks,
        "fraud_rate": float(df["label"].mean())
    }

    with open(output_report.path, "w") as f:
        json.dump(report, f, indent=2)

    print(f"Validation {'PASSED ✅' if passed else 'FAILED ❌'}")
    if failed_checks:
        print(f"Failed checks: {failed_checks}")

    from collections import namedtuple
    return namedtuple("ValidationResult", ["passed", "row_count"])(
        passed=passed,
        row_count=len(df)
    )


# ── Component 2: Feature Engineering ─────────────────────────
@component(
    base_image="python:3.12-slim",
    packages_to_install=["pandas==2.0.3", "scikit-learn==1.4.0"]
)
def engineer_features(
    data_uri: str,
    output_dataset: Output[Dataset]
):
    """Transform raw data into model-ready features."""
    import pandas as pd
    from sklearn.preprocessing import StandardScaler
    import pickle

    df = pd.read_parquet(data_uri)

    # Feature engineering
    df["amount_log"] = df["amount"].apply(lambda x: max(x, 0.01)).apply(__import__("math").log)
    df["hour_of_day"] = pd.to_datetime(df["timestamp"]).dt.hour
    df["is_weekend"] = pd.to_datetime(df["timestamp"]).dt.dayofweek >= 5
    df["velocity_7d"] = df.groupby("user_id")["amount"].transform(
        lambda x: x.rolling(7, min_periods=1).mean()
    )

    # Save processed dataset
    df.to_parquet(output_dataset.path, index=False)
    print(f"✅ Feature engineering complete: {len(df)} rows, {len(df.columns)} features")


# ── Component 3: Model Training ───────────────────────────────
@component(
    base_image="python:3.12-slim",
    packages_to_install=["pandas==2.0.3", "scikit-learn==1.4.0",
                          "mlflow==2.10.0", "boto3==1.34.0"]
)
def train_model(
    dataset: Input[Dataset],
    hyperparams: dict,
    mlflow_tracking_uri: str,
    output_model: Output[Model],
    metrics_output: Output[Metrics]
):
    """Train fraud detection model and log to MLflow."""
    import pandas as pd
    from sklearn.ensemble import GradientBoostingClassifier
    from sklearn.model_selection import train_test_split, StratifiedKFold
    from sklearn.metrics import f1_score, roc_auc_score, precision_score, recall_score
    import mlflow
    import pickle

    # Load data
    df = pd.read_parquet(dataset.path)
    feature_cols = [c for c in df.columns if c not in ["label", "transaction_id", "timestamp", "user_id"]]
    X = df[feature_cols]
    y = df["label"]

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, stratify=y, random_state=42
    )

    # Train
    mlflow.set_tracking_uri(mlflow_tracking_uri)
    with mlflow.start_run():
        model = GradientBoostingClassifier(**hyperparams, random_state=42)
        model.fit(X_train, y_train)

        predictions = model.predict(X_test)
        proba = model.predict_proba(X_test)[:, 1]

        # Calculate metrics
        results = {
            "f1_score":       f1_score(y_test, predictions),
            "auc_roc":        roc_auc_score(y_test, proba),
            "precision":      precision_score(y_test, predictions),
            "recall":         recall_score(y_test, predictions),
            "train_samples":  len(X_train),
        }

        mlflow.log_params(hyperparams)
        mlflow.log_metrics(results)
        mlflow.sklearn.log_model(model, "model", registered_model_name="fraud-detector")

        # Log KFP metrics
        metrics_output.log_metric("f1_score", results["f1_score"])
        metrics_output.log_metric("auc_roc", results["auc_roc"])

    # Save model
    with open(output_model.path, "wb") as f:
        pickle.dump(model, f)

    print(f"✅ Training complete: F1={results['f1_score']:.3f}, AUC={results['auc_roc']:.3f}")


# ── Component 4: Model Evaluation Gate ───────────────────────
@component(base_image="python:3.12-slim")
def evaluate_model(
    model: Input[Model],
    metrics: Input[Metrics],
    min_f1_threshold: float = 0.75,
    min_auc_threshold: float = 0.85,
) -> bool:
    """Quality gate: only pass if metrics meet production standards."""
    import json

    with open(metrics.path) as f:
        metric_data = json.load(f)

    f1 = metric_data.get("f1_score", 0)
    auc = metric_data.get("auc_roc", 0)

    passed = f1 >= min_f1_threshold and auc >= min_auc_threshold

    print(f"Quality Gate: F1={f1:.3f} (min {min_f1_threshold}), AUC={auc:.3f} (min {min_auc_threshold})")
    print(f"Result: {'PASSED ✅' if passed else 'FAILED ❌'}")

    return passed


# ── Component 5: Deploy to Kubernetes ────────────────────────
@component(
    base_image="bitnami/kubectl:1.29",
    packages_to_install=[]
)
def deploy_model(
    model_name: str,
    model_version: str,
    namespace: str = "production"
):
    """Deploy model to KServe InferenceService."""
    import subprocess

    manifest = f"""
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: {model_name}
  namespace: {namespace}
spec:
  predictor:
    model:
      modelFormat:
        name: sklearn
      storageUri: s3://mlmodels/{model_name}/v{model_version}/
      resources:
        requests:
          cpu: 500m
          memory: 1Gi
        limits:
          cpu: 2000m
          memory: 4Gi
    minReplicas: 2
    maxReplicas: 10
"""
    result = subprocess.run(["kubectl", "apply", "-f", "-"],
                             input=manifest, capture_output=True, text=True)
    print(result.stdout)
    if result.returncode != 0:
        raise RuntimeError(f"Deployment failed: {result.stderr}")

    print(f"✅ Deployed {model_name} v{model_version} to {namespace}")


# ── Pipeline Definition ───────────────────────────────────────
@dsl.pipeline(
    name="fraud-detection-training-pipeline",
    description="End-to-end fraud model training, evaluation, and deployment"
)
def fraud_pipeline(
    data_uri: str = "s3://my-bucket/data/transactions/2024-01.parquet",
    mlflow_tracking_uri: str = "http://mlflow.mlflow:5000",
    min_f1: float = 0.75,
    hyperparams: dict = {
        "n_estimators": 200,
        "learning_rate": 0.05,
        "max_depth": 6
    }
):
    # Step 1: Validate data
    validation = validate_data(data_uri=data_uri)

    # Step 2: Fail fast if data is bad
    with dsl.Condition(validation.outputs["passed"] == True):

        # Step 3: Engineer features
        features = engineer_features(data_uri=data_uri)

        # Step 4: Train model
        training = train_model(
            dataset=features.outputs["output_dataset"],
            hyperparams=hyperparams,
            mlflow_tracking_uri=mlflow_tracking_uri
        )

        # Step 5: Quality gate
        evaluation = evaluate_model(
            model=training.outputs["output_model"],
            metrics=training.outputs["metrics_output"],
            min_f1_threshold=min_f1
        )

        # Step 6: Deploy only if quality gate passes
        with dsl.Condition(evaluation.output == True):
            deploy_model(
                model_name="fraud-detector",
                model_version="latest",
                namespace="production"
            )


if __name__ == "__main__":
    # Compile to YAML for Kubeflow Pipelines UI
    compiler.Compiler().compile(fraud_pipeline, "fraud_pipeline.yaml")
    print("✅ Pipeline compiled to fraud_pipeline.yaml")

    # Submit to Kubeflow (requires KFP client)
    # import kfp
    # client = kfp.Client(host="http://kubeflow.company.com")
    # run = client.create_run_from_pipeline_func(
    #     fraud_pipeline,
    #     arguments={"min_f1": 0.80}
    # )
    # print(f"Pipeline run: {run.run_info.id}")
