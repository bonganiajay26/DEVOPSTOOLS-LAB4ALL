"""
Unit tests — tagging strategy validation.

Validates that tag strings and configurations conform to Quantum's tagging standards
without requiring a live agent or API connection.
"""

import pytest
import re

REQUIRED_TAGS = {"env", "service", "team"}
VALID_ENVS = {"production", "staging", "development", "test"}
TAG_PATTERN = re.compile(r"^[a-z0-9_][a-z0-9_.\-/]*:[a-z0-9_.\-/]+$")
MAX_TAG_LENGTH = 200
MAX_TAG_COUNT = 100


def parse_tags(tag_list: list[str]) -> dict[str, str]:
    result = {}
    for tag in tag_list:
        if ":" in tag:
            key, _, value = tag.partition(":")
            result[key] = value
    return result


# ── Tag format validation ─────────────────────────────────────────

class TestTagFormat:
    def test_valid_tag_passes(self):
        assert TAG_PATTERN.match("env:production")
        assert TAG_PATTERN.match("team:backend-payments")
        assert TAG_PATTERN.match("service:api-gateway")
        assert TAG_PATTERN.match("region:us-east-1")

    def test_uppercase_fails(self):
        assert not TAG_PATTERN.match("Env:Production")
        assert not TAG_PATTERN.match("ENV:PRODUCTION")

    def test_space_in_value_fails(self):
        assert not TAG_PATTERN.match("team:backend payments")

    def test_missing_value_fails(self):
        assert not TAG_PATTERN.match("env:")
        assert not TAG_PATTERN.match("env")

    def test_tag_length_limit(self):
        long_value = "x" * (MAX_TAG_LENGTH + 1)
        tag = f"env:{long_value}"
        assert len(tag) > MAX_TAG_LENGTH

    @pytest.mark.parametrize("tag", [
        "env:production",
        "team:platform",
        "service:payment-service",
        "region:us-east-1",
        "datacenter:aws",
        "version:1.2.3",
    ])
    def test_valid_standard_tags(self, tag):
        assert TAG_PATTERN.match(tag), f"Tag failed validation: {tag}"


# ── Required tag presence ─────────────────────────────────────────

class TestRequiredTags:
    def test_all_required_tags_present(self):
        tags = ["env:production", "service:api-gateway", "team:platform"]
        parsed = parse_tags(tags)
        missing = REQUIRED_TAGS - set(parsed.keys())
        assert not missing, f"Missing required tags: {missing}"

    def test_missing_env_tag_detected(self):
        tags = ["service:api-gateway", "team:platform"]
        parsed = parse_tags(tags)
        missing = REQUIRED_TAGS - set(parsed.keys())
        assert "env" in missing

    def test_missing_service_tag_detected(self):
        tags = ["env:production", "team:platform"]
        parsed = parse_tags(tags)
        missing = REQUIRED_TAGS - set(parsed.keys())
        assert "service" in missing

    def test_empty_tag_list_fails(self):
        parsed = parse_tags([])
        missing = REQUIRED_TAGS - set(parsed.keys())
        assert missing == REQUIRED_TAGS


# ── Environment value validation ──────────────────────────────────

class TestEnvTagValues:
    @pytest.mark.parametrize("env", list(VALID_ENVS))
    def test_valid_env_values(self, env):
        tags = parse_tags([f"env:{env}", "service:x", "team:x"])
        assert tags.get("env") in VALID_ENVS

    def test_invalid_env_value_detected(self):
        tags = parse_tags(["env:prod", "service:x", "team:x"])  # 'prod' not in VALID_ENVS
        assert tags.get("env") not in VALID_ENVS

    def test_production_not_abbreviated(self):
        tags = parse_tags(["env:prod"])
        assert tags.get("env") != "production"  # flags the abbreviation


# ── High cardinality tag detection ───────────────────────────────

class TestHighCardinalityTags:
    HIGH_CARDINALITY_KEYS = {"user_id", "request_id", "session_id", "transaction_id"}

    def test_no_high_cardinality_tags(self):
        tags = ["env:production", "service:api", "team:backend"]
        parsed = parse_tags(tags)
        violations = self.HIGH_CARDINALITY_KEYS & set(parsed.keys())
        assert not violations, f"High cardinality tags found: {violations}"

    def test_detects_user_id_tag(self):
        tags = ["env:production", "user_id:12345"]
        parsed = parse_tags(tags)
        violations = self.HIGH_CARDINALITY_KEYS & set(parsed.keys())
        assert "user_id" in violations

    def test_pii_not_in_tags(self):
        pii_patterns = [re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b")]
        tags = ["env:production", "service:api"]
        for tag in tags:
            for pattern in pii_patterns:
                assert not pattern.search(tag), f"PII found in tag: {tag}"
