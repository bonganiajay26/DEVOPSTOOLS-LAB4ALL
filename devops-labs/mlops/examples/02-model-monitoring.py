#!/usr/bin/env python3
"""
Example 02: ML Model Monitoring — Drift Detection and Performance Tracking
Monitors a deployed model for data drift, model drift, and performance degradation.
"""

import pandas as pd
import numpy as np
from datetime import datetime, timedelta
import json
import logging
from typing import Optional

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


# ── 1. Data Drift Detection ───────────────────────────────────

class DataDriftMonitor:
    """Monitor feature distributions for drift vs training baseline."""

    def __init__(self, reference_data: pd.DataFrame, threshold_psi: float = 0.1):
        self.reference = reference_data
        self.threshold = threshold_psi
        self.stats = self._compute_reference_stats()

    def _compute_reference_stats(self) -> dict:
        """Compute reference statistics for each feature."""
        stats = {}
        for col in self.reference.select_dtypes(include=[np.number]).columns:
            stats[col] = {
                "mean": float(self.reference[col].mean()),
                "std": float(self.reference[col].std()),
                "min": float(self.reference[col].min()),
                "max": float(self.reference[col].max()),
                "percentiles": {
                    str(p): float(np.percentile(self.reference[col].dropna(), p))
                    for p in [10, 25, 50, 75, 90]
                }
            }
        return stats

    def compute_psi(self, reference: pd.Series, current: pd.Series,
                    n_bins: int = 10) -> float:
        """
        Population Stability Index (PSI):
        PSI < 0.1 → No drift (green)
        PSI 0.1-0.2 → Moderate drift (yellow — investigate)
        PSI > 0.2 → Significant drift (red — action required)
        """
        # Create bins from reference distribution
        min_val = min(reference.min(), current.min())
        max_val = max(reference.max(), current.max())
        bins = np.linspace(min_val, max_val, n_bins + 1)

        # Compute proportions in each bin
        ref_counts, _ = np.histogram(reference.dropna(), bins=bins)
        cur_counts, _ = np.histogram(current.dropna(), bins=bins)

        # Avoid division by zero
        ref_pct = np.where(ref_counts == 0, 0.0001, ref_counts / len(reference))
        cur_pct = np.where(cur_counts == 0, 0.0001, cur_counts / len(current))

        # PSI formula: sum((current% - reference%) * ln(current% / reference%))
        psi = np.sum((cur_pct - ref_pct) * np.log(cur_pct / ref_pct))
        return float(psi)

    def check_drift(self, current_data: pd.DataFrame) -> dict:
        """Check for drift in all numeric features."""
        results = {
            "timestamp": datetime.utcnow().isoformat(),
            "features": {},
            "overall_drift": False,
            "drifted_features": []
        }

        for col in self.reference.select_dtypes(include=[np.number]).columns:
            if col not in current_data.columns:
                continue

            psi = self.compute_psi(self.reference[col], current_data[col])
            status = (
                "red" if psi > 0.2 else
                "yellow" if psi > 0.1 else
                "green"
            )

            results["features"][col] = {
                "psi": round(psi, 4),
                "status": status,
                "ref_mean": self.stats[col]["mean"],
                "cur_mean": float(current_data[col].mean()),
                "pct_change": abs(float(current_data[col].mean()) - self.stats[col]["mean"]) /
                              max(abs(self.stats[col]["mean"]), 0.0001) * 100
            }

            if psi > self.threshold:
                results["drifted_features"].append(col)
                results["overall_drift"] = True

        return results


# ── 2. Model Performance Tracker ─────────────────────────────

class ModelPerformanceTracker:
    """Track model predictions and ground truth for performance monitoring."""

    def __init__(self, model_name: str, window_days: int = 7):
        self.model_name = model_name
        self.window_days = window_days
        self.predictions = []
        self.ground_truths = []

    def log_prediction(self, prediction: float, probability: float,
                       actual: Optional[float] = None,
                       metadata: dict = None):
        """Log a prediction with optional ground truth."""
        record = {
            "timestamp": datetime.utcnow().isoformat(),
            "prediction": prediction,
            "probability": probability,
            "actual": actual,
            "metadata": metadata or {}
        }
        self.predictions.append(record)

        if actual is not None:
            self.ground_truths.append(record)

    def compute_metrics(self) -> dict:
        """Compute performance metrics over the window."""
        if not self.ground_truths:
            return {"error": "No ground truth data available"}

        df = pd.DataFrame(self.ground_truths)
        df["timestamp"] = pd.to_datetime(df["timestamp"])
        cutoff = datetime.utcnow() - timedelta(days=self.window_days)
        df = df[df["timestamp"] > cutoff]

        if len(df) < 10:
            return {"warning": f"Insufficient data: only {len(df)} labeled samples"}

        y_true = df["actual"].values
        y_pred = df["prediction"].values
        y_prob = df["probability"].values

        from sklearn.metrics import (
            accuracy_score, f1_score, roc_auc_score,
            precision_score, recall_score
        )

        metrics = {
            "window_days": self.window_days,
            "sample_count": len(df),
            "accuracy":  round(float(accuracy_score(y_true, y_pred)), 4),
            "f1_score":  round(float(f1_score(y_true, y_pred, zero_division=0)), 4),
            "precision": round(float(precision_score(y_true, y_pred, zero_division=0)), 4),
            "recall":    round(float(recall_score(y_true, y_pred, zero_division=0)), 4),
            "auc_roc":   round(float(roc_auc_score(y_true, y_prob)) if len(np.unique(y_true)) > 1 else 0.0, 4),
            "avg_confidence": round(float(np.mean(y_prob)), 4),
            "low_confidence_pct": round(float((y_prob < 0.6).mean() * 100), 2),
        }

        return metrics

    def should_retrain(self, baseline_f1: float = 0.80,
                       degradation_threshold: float = 0.05) -> dict:
        """Determine if model should be retrained based on performance."""
        metrics = self.compute_metrics()

        if "error" in metrics or "warning" in metrics:
            return {"retrain": False, "reason": metrics.get("error") or metrics.get("warning")}

        current_f1 = metrics.get("f1_score", 0)
        degradation = baseline_f1 - current_f1

        decision = {
            "retrain": degradation > degradation_threshold,
            "current_f1": current_f1,
            "baseline_f1": baseline_f1,
            "degradation": round(degradation, 4),
            "reason": (
                f"Performance degraded by {degradation:.1%} below baseline"
                if degradation > degradation_threshold
                else "Performance acceptable"
            )
        }

        return decision


# ── 3. Complete Monitoring Pipeline ──────────────────────────

def run_monitoring_check(
    reference_data_path: str = None,
    current_data_path: str = None
) -> dict:
    """
    Run a complete monitoring check:
    1. Load reference and current data
    2. Check for data drift
    3. Evaluate model performance
    4. Determine if retraining is needed
    """
    logger.info("Starting monitoring check...")

    # Use synthetic data for demo
    np.random.seed(42)
    n_samples = 1000

    # Reference data (training distribution)
    reference = pd.DataFrame({
        "feature_1": np.random.normal(0, 1, n_samples),
        "feature_2": np.random.exponential(1, n_samples),
        "feature_3": np.random.uniform(-1, 1, n_samples),
        "amount": np.random.lognormal(4, 1, n_samples),
    })

    # Current production data — introduce drift in feature_2
    current = pd.DataFrame({
        "feature_1": np.random.normal(0.1, 1.1, n_samples // 2),    # Slight drift
        "feature_2": np.random.exponential(2.0, n_samples // 2),    # DRIFT! Mean doubled
        "feature_3": np.random.uniform(-1, 1, n_samples // 2),      # No drift
        "amount": np.random.lognormal(4.5, 1, n_samples // 2),      # Slight drift
    })

    # 1. Data drift check
    drift_monitor = DataDriftMonitor(reference, threshold_psi=0.1)
    drift_results = drift_monitor.check_drift(current)

    logger.info(f"Drift check complete. Overall drift: {drift_results['overall_drift']}")
    if drift_results["drifted_features"]:
        logger.warning(f"Drifted features: {drift_results['drifted_features']}")

    # 2. Performance tracking simulation
    tracker = ModelPerformanceTracker("fraud_detector_v2")
    for i in range(500):
        is_fraud = np.random.binomial(1, 0.05)  # 5% fraud rate
        prob = np.random.beta(2, 10) if not is_fraud else np.random.beta(8, 2)
        pred = 1 if prob > 0.5 else 0
        tracker.log_prediction(pred, prob, actual=float(is_fraud))

    perf_metrics = tracker.compute_metrics()
    retrain_decision = tracker.should_retrain(baseline_f1=0.80)

    # 3. Compile report
    report = {
        "check_timestamp": datetime.utcnow().isoformat(),
        "model_name": "fraud_detector_v2",
        "data_drift": {
            "overall_drift_detected": drift_results["overall_drift"],
            "drifted_features": drift_results["drifted_features"],
            "feature_details": {
                k: {"psi": v["psi"], "status": v["status"]}
                for k, v in drift_results["features"].items()
            }
        },
        "performance": perf_metrics,
        "retraining": retrain_decision,
        "recommended_action": (
            "RETRAIN IMMEDIATELY" if retrain_decision["retrain"] else
            "INVESTIGATE DRIFT" if drift_results["overall_drift"] else
            "NO ACTION REQUIRED"
        )
    }

    return report


if __name__ == "__main__":
    report = run_monitoring_check()
    print(json.dumps(report, indent=2))

    print("\n=== Summary ===")
    print(f"Recommended Action: {report['recommended_action']}")
    print(f"Drift Features: {report['data_drift']['drifted_features']}")
    print(f"Model F1: {report['performance'].get('f1_score', 'N/A')}")
    print(f"Retrain: {report['retraining']['retrain']} — {report['retraining']['reason']}")
