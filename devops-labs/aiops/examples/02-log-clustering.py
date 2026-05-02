#!/usr/bin/env python3
"""
Example 02: Log Clustering and Anomaly Detection using Drain3
Groups similar log lines into templates and detects anomalous patterns.
"""

import re
import json
import logging
from datetime import datetime
from collections import defaultdict, deque
from typing import List, Tuple, Optional
import statistics

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


# ── Simple Log Template Miner (Drain-inspired) ────────────────

class SimpleLogMiner:
    """
    Simplified log template mining.
    Groups similar log lines by extracting variable parts.
    """

    def __init__(self, similarity_threshold: float = 0.5,
                 max_children: int = 100):
        self.templates = {}           # id -> template
        self.template_counts = {}     # id -> occurrence count
        self.template_id_counter = 0
        self.similarity_threshold = similarity_threshold

    def _tokenize(self, log_line: str) -> List[str]:
        """Split log line into tokens."""
        # Replace common variable patterns
        line = re.sub(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b', '<IP>', log_line)
        line = re.sub(r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '<UUID>', line)
        line = re.sub(r'\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}', '<TIMESTAMP>', line)
        line = re.sub(r'\b\d+\b', '<NUM>', line)
        return line.split()

    def _similarity(self, t1: List[str], t2: List[str]) -> float:
        """Compute similarity ratio between two token sequences."""
        if not t1 or not t2:
            return 0.0
        shorter = min(len(t1), len(t2))
        longer  = max(len(t1), len(t2))
        matches = sum(1 for a, b in zip(t1, t2) if a == b)
        return matches / longer

    def add_log_line(self, log_line: str) -> Tuple[int, bool]:
        """
        Add a log line. Returns (template_id, is_new_template).
        """
        tokens = self._tokenize(log_line)

        # Find most similar existing template
        best_id = None
        best_sim = 0.0

        for tid, template in self.templates.items():
            sim = self._similarity(tokens, template)
            if sim > best_sim:
                best_sim = sim
                best_id = tid

        if best_sim >= self.similarity_threshold and best_id is not None:
            # Merge into existing template: wildcards where tokens differ
            existing = self.templates[best_id]
            merged = [
                a if a == b else '<*>'
                for a, b in zip(existing, tokens)
            ]
            # Handle length differences
            if len(tokens) > len(existing):
                merged.extend(['<*>'] * (len(tokens) - len(existing)))
            self.templates[best_id] = merged
            self.template_counts[best_id] += 1
            return best_id, False
        else:
            # New template
            self.template_id_counter += 1
            new_id = self.template_id_counter
            self.templates[new_id] = tokens
            self.template_counts[new_id] = 1
            logger.info(f"New template {new_id}: {' '.join(tokens[:10])}")
            return new_id, True

    def get_template(self, template_id: int) -> str:
        """Get the template string for a given ID."""
        return ' '.join(self.templates.get(template_id, ['<unknown>']))


# ── Log Volume Anomaly Detection ──────────────────────────────

class LogVolumeAnomalyDetector:
    """
    Detects unusual log volume patterns.
    Tracks counts per time window and flags deviations.
    """

    def __init__(self, window_minutes: int = 5,
                 history_windows: int = 20,
                 z_threshold: float = 3.0):
        self.window_minutes = window_minutes
        self.z_threshold = z_threshold
        self.history = deque(maxlen=history_windows)  # Rolling window counts
        self.template_history = defaultdict(lambda: deque(maxlen=history_windows))
        self.current_window_start = datetime.utcnow()
        self.current_counts = defaultdict(int)

    def _rotate_window(self):
        """Move current window to history and start fresh."""
        if self.current_counts:
            self.history.append(dict(self.current_counts))
            for tid, count in self.current_counts.items():
                self.template_history[tid].append(count)
        self.current_counts = defaultdict(int)
        self.current_window_start = datetime.utcnow()

    def add_log(self, template_id: int):
        """Add a log event, rotating window if needed."""
        now = datetime.utcnow()
        elapsed = (now - self.current_window_start).total_seconds() / 60

        if elapsed >= self.window_minutes:
            self._rotate_window()

        self.current_counts[template_id] += 1

    def check_anomalies(self) -> List[dict]:
        """Check current window for anomalous volumes."""
        if len(self.history) < 5:
            return []  # Not enough history yet

        anomalies = []

        for tid, count in self.current_counts.items():
            hist = list(self.template_history[tid])
            if len(hist) < 5:
                continue

            mean = statistics.mean(hist)
            try:
                std = statistics.stdev(hist)
            except statistics.StatisticsError:
                continue

            if std == 0:
                if count > mean * 2:  # 2x normal with no variance
                    zscore = 99.0
                else:
                    continue
            else:
                zscore = (count - mean) / std

            if abs(zscore) > self.z_threshold:
                anomalies.append({
                    "template_id": tid,
                    "current_count": count,
                    "mean_count": round(mean, 1),
                    "std": round(std, 1),
                    "z_score": round(zscore, 2),
                    "direction": "above_normal" if zscore > 0 else "below_normal",
                    "severity": (
                        "critical" if abs(zscore) > 5 else
                        "high"     if abs(zscore) > 4 else
                        "warning"
                    )
                })

        return sorted(anomalies, key=lambda x: abs(x["z_score"]), reverse=True)


# ── Main Pipeline ─────────────────────────────────────────────

def simulate_production_logs(n_logs: int = 500) -> List[str]:
    """Generate realistic production log lines for demo."""
    import random
    templates = [
        "INFO user 12345 logged in from 192.168.1.1",
        "INFO processing order 67890 for user 12345",
        "DEBUG cache miss for key session:abc123",
        "INFO payment processed successfully for order 67890 amount 99.99",
        "WARNING high memory usage: 85% on pod myapp-xyz",
        "ERROR database connection failed: timeout after 30s",
        "INFO request GET /api/users 200 23ms",
        "INFO request POST /api/orders 201 145ms",
        "ERROR request POST /api/checkout 500 1234ms internal error",
        "INFO background job completed: send_email duration=2.3s",
    ]

    logs = []
    for i in range(n_logs):
        # Inject an anomaly: ERROR spike between logs 300-350
        if 300 <= i <= 350:
            logs.append(
                f"ERROR database connection failed: timeout after {random.randint(20, 60)}s "
                f"retry {random.randint(1, 5)}/5 host db-{random.randint(1,3)}.prod"
            )
        else:
            # Normal distribution of log types
            template = random.choices(
                templates,
                weights=[10, 8, 15, 5, 3, 2, 20, 12, 1, 5]
            )[0]
            # Add some variation
            template = re.sub(r'\d+', lambda m: str(int(m.group()) + random.randint(-5, 5)), template)
            logs.append(template)

    return logs


def run_log_analysis():
    """Run complete log analysis pipeline."""
    print("=== Log Anomaly Detection Pipeline ===\n")

    # Initialize components
    miner = SimpleLogMiner(similarity_threshold=0.5)
    volume_detector = LogVolumeAnomalyDetector(
        window_minutes=5,
        history_windows=20,
        z_threshold=2.5
    )

    # Process logs
    logs = simulate_production_logs(500)
    template_stats = defaultdict(int)

    print(f"Processing {len(logs)} log lines...")

    for i, log_line in enumerate(logs):
        template_id, is_new = miner.add_log_line(log_line)
        template_stats[template_id] += 1

        # Simulate time windows (every 50 logs = new window)
        if i % 50 == 0 and i > 0:
            volume_detector._rotate_window()

        volume_detector.add_log(template_id)

    # Results
    print(f"\n✅ Analysis complete!")
    print(f"   Total logs processed: {len(logs)}")
    print(f"   Unique log templates found: {len(miner.templates)}")

    print("\n--- Top 5 Most Common Templates ---")
    sorted_templates = sorted(template_stats.items(), key=lambda x: x[1], reverse=True)[:5]
    for tid, count in sorted_templates:
        template_str = miner.get_template(tid)[:80]
        print(f"  [{count:4d}x] {template_str}")

    print("\n--- Volume Anomalies ---")
    anomalies = volume_detector.check_anomalies()
    if anomalies:
        for anomaly in anomalies:
            template_str = miner.get_template(anomaly["template_id"])[:60]
            print(
                f"  [{anomaly['severity'].upper()}] Z={anomaly['z_score']:+.1f} "
                f"count={anomaly['current_count']} (avg={anomaly['mean_count']}) "
                f"| {template_str}"
            )
    else:
        print("  No volume anomalies detected in current window")

    print("\n--- New Templates (unknown patterns) ---")
    new_templates = [(tid, miner.get_template(tid)) for tid in miner.templates
                     if template_stats[tid] <= 2][:5]
    for tid, template in new_templates:
        print(f"  Template {tid}: {template[:80]}")


if __name__ == "__main__":
    run_log_analysis()
