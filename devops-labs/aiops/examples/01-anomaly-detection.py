#!/usr/bin/env python3
"""
Example 01: Production Anomaly Detection System
Uses Prophet for time series and Isolation Forest for multivariate anomalies.
"""

import pandas as pd
import numpy as np
from datetime import datetime, timedelta
from typing import Optional
import json
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


# ── 1. Generate Synthetic Metric Data ─────────────────────────

def generate_metric_data(days: int = 30, spike_at_day: int = 25) -> pd.DataFrame:
    """Generate realistic API request rate data with seasonality and anomaly."""
    timestamps = pd.date_range(
        start=datetime.now() - timedelta(days=days),
        end=datetime.now(),
        freq='5min'
    )

    data = []
    for ts in timestamps:
        hour = ts.hour
        day_of_week = ts.dayofweek

        # Business hours pattern (higher during 9-5, M-F)
        if day_of_week < 5:  # Weekday
            if 9 <= hour <= 17:
                base = 1000 + (hour - 9) * 50
            else:
                base = 200
        else:  # Weekend
            base = 100

        # Add seasonality and noise
        noise = np.random.normal(0, base * 0.05)
        value = max(0, base + noise)

        # Inject anomaly on spike_at_day
        if ts.date() == (datetime.now() - timedelta(days=days - spike_at_day)).date():
            if 14 <= hour <= 16:
                value *= 8  # 8x traffic spike!

        data.append({"timestamp": ts, "requests_per_minute": value})

    return pd.DataFrame(data)


# ── 2. Prophet-Based Anomaly Detection ────────────────────────

class TimeSeriesAnomalyDetector:
    """Detect anomalies using Facebook Prophet time series model."""

    def __init__(self, interval_width: float = 0.99):
        self.interval_width = interval_width
        self.model = None

    def fit(self, df: pd.DataFrame):
        """Train on historical data."""
        try:
            from prophet import Prophet
        except ImportError:
            logger.warning("prophet not installed. Run: pip install prophet")
            return self

        prophet_df = df.rename(columns={
            "timestamp": "ds",
            "requests_per_minute": "y"
        })

        self.model = Prophet(
            interval_width=self.interval_width,
            seasonality_mode='multiplicative',
            daily_seasonality=True,
            weekly_seasonality=True,
            changepoint_prior_scale=0.05,
        )
        self.model.fit(prophet_df)
        logger.info("✅ Prophet model trained")
        return self

    def detect(self, df: pd.DataFrame) -> pd.DataFrame:
        """Detect anomalies in new data."""
        if self.model is None:
            raise ValueError("Model not fitted. Call fit() first.")

        prophet_df = df.rename(columns={
            "timestamp": "ds",
            "requests_per_minute": "y"
        })

        forecast = self.model.predict(prophet_df[["ds"]])
        result = prophet_df.merge(
            forecast[["ds", "yhat", "yhat_lower", "yhat_upper"]],
            on="ds",
            how="left"
        )

        # Flag anomalies
        result["is_anomaly"] = (
            (result["y"] > result["yhat_upper"]) |
            (result["y"] < result["yhat_lower"])
        )
        result["anomaly_score"] = np.where(
            result["y"] > result["yhat_upper"],
            (result["y"] - result["yhat_upper"]) / result["yhat_upper"],
            np.where(
                result["y"] < result["yhat_lower"],
                (result["yhat_lower"] - result["y"]) / result["yhat_lower"],
                0
            )
        )

        anomalies = result[result["is_anomaly"]]
        logger.info(f"Detected {len(anomalies)} anomalies "
                    f"({len(anomalies)/len(result)*100:.1f}% of data points)")

        return result


# ── 3. Isolation Forest for Multivariate Anomalies ────────────

class MultivariateAnomalyDetector:
    """Detect anomalies across multiple metrics simultaneously."""

    def __init__(self, contamination: float = 0.01):
        self.contamination = contamination
        self.model = None
        self.scaler = None
        self.feature_names = None

    def fit(self, df: pd.DataFrame):
        """Train on historical multi-metric data."""
        from sklearn.ensemble import IsolationForest
        from sklearn.preprocessing import StandardScaler

        self.feature_names = df.columns.tolist()
        self.scaler = StandardScaler()
        X_scaled = self.scaler.fit_transform(df)

        self.model = IsolationForest(
            contamination=self.contamination,
            n_estimators=100,
            random_state=42,
            n_jobs=-1
        )
        self.model.fit(X_scaled)
        logger.info(f"✅ Isolation Forest trained on {len(df)} samples, {len(self.feature_names)} features")
        return self

    def detect(self, df: pd.DataFrame) -> pd.DataFrame:
        """Score new data points."""
        X_scaled = self.scaler.transform(df)
        scores = self.model.score_samples(X_scaled)   # More negative = more anomalous
        predictions = self.model.predict(X_scaled)    # -1 = anomaly, 1 = normal

        result = df.copy()
        result["anomaly_score"] = -scores              # Positive = more anomalous
        result["is_anomaly"] = predictions == -1

        # Find which feature contributed most to anomaly
        if result["is_anomaly"].any():
            anomaly_rows = result[result["is_anomaly"]]
            for idx, row in anomaly_rows.iterrows():
                deviations = abs((row[self.feature_names] - df.mean()) / df.std())
                result.at[idx, "top_feature"] = deviations.idxmax()

        return result


# ── 4. Alert Generation ────────────────────────────────────────

class AnomalyAlerter:
    """Convert detected anomalies into structured alerts."""

    def __init__(self, min_score: float = 0.5):
        self.min_score = min_score

    def generate_alerts(
        self,
        anomalies: pd.DataFrame,
        metric_name: str,
        service: str
    ) -> list[dict]:
        """Generate alert objects from detected anomalies."""
        alerts = []
        significant = anomalies[
            anomalies["is_anomaly"] &
            (anomalies["anomaly_score"] >= self.min_score)
        ]

        for _, row in significant.iterrows():
            severity = (
                "critical" if row["anomaly_score"] > 2.0 else
                "high"     if row["anomaly_score"] > 1.0 else
                "warning"
            )

            alert = {
                "id": f"ANOM-{row.name}",
                "timestamp": str(row["ds"]) if "ds" in row else str(row.name),
                "metric": metric_name,
                "service": service,
                "severity": severity,
                "current_value": round(float(row.get("y", row.get("value", 0))), 2),
                "expected_value": round(float(row.get("yhat", 0)), 2) if "yhat" in row else None,
                "anomaly_score": round(float(row["anomaly_score"]), 3),
                "direction": "above_expected" if row.get("y", 0) > row.get("yhat", 0) else "below_expected",
                "description": self._generate_description(row, metric_name, service),
            }
            alerts.append(alert)

        return alerts

    def _generate_description(self, row, metric_name, service) -> str:
        current = row.get("y", row.get("value", 0))
        expected = row.get("yhat", 0)
        pct_deviation = abs(current - expected) / max(expected, 1) * 100

        return (
            f"{service} {metric_name} is {pct_deviation:.0f}% "
            f"{'above' if current > expected else 'below'} expected value "
            f"({current:.1f} vs expected {expected:.1f})"
        )


# ── 5. Main: Full Pipeline ─────────────────────────────────────

def run_anomaly_detection():
    print("=== AIOps Anomaly Detection Pipeline ===\n")

    # Generate test data
    print("1. Generating metric data...")
    df = generate_metric_data(days=30, spike_at_day=25)
    print(f"   Generated {len(df)} data points over 30 days\n")

    # Split: 25 days training, 5 days detection
    train_cutoff = datetime.now() - timedelta(days=5)
    train_df = df[df["timestamp"] < train_cutoff]
    test_df = df[df["timestamp"] >= train_cutoff]

    # Train anomaly detector
    print("2. Training Prophet anomaly detector...")
    detector = TimeSeriesAnomalyDetector(interval_width=0.99)
    detector.fit(train_df)

    # Detect anomalies in recent data
    print("\n3. Running anomaly detection on recent data...")
    try:
        results = detector.detect(test_df)
        anomalies = results[results["is_anomaly"]]

        print(f"\nResults:")
        print(f"  Total data points: {len(results)}")
        print(f"  Anomalies detected: {len(anomalies)}")

        if not anomalies.empty:
            print(f"\nAnomalous timestamps:")
            for _, row in anomalies.iterrows():
                print(f"  {row['ds']}: {row['y']:.0f} req/min "
                      f"(expected {row['yhat']:.0f}, score {row['anomaly_score']:.2f})")

        # Generate alerts
        print("\n4. Generating alerts...")
        alerter = AnomalyAlerter(min_score=0.3)
        alerts = alerter.generate_alerts(
            results, "requests_per_minute", "api-service"
        )

        for alert in alerts:
            print(f"\n  [{alert['severity'].upper()}] {alert['id']}")
            print(f"  {alert['description']}")
            print(f"  Score: {alert['anomaly_score']}")

    except Exception as e:
        logger.warning(f"Prophet not available ({e}), using simplified detection")
        # Fallback: Z-score based detection
        mean = train_df["requests_per_minute"].mean()
        std = train_df["requests_per_minute"].std()
        test_df = test_df.copy()
        test_df["z_score"] = (test_df["requests_per_minute"] - mean) / std
        test_df["is_anomaly"] = abs(test_df["z_score"]) > 3

        anomalies = test_df[test_df["is_anomaly"]]
        print(f"  Z-score anomalies detected: {len(anomalies)}")
        for _, row in anomalies.iterrows():
            print(f"  {row['timestamp']}: {row['requests_per_minute']:.0f} req/min "
                  f"(Z={row['z_score']:.2f})")

    print("\n✅ Anomaly detection pipeline complete!")


if __name__ == "__main__":
    run_anomaly_detection()
