"""
CLA-87: MEMOS Recall Fix — Neo4j info serialization round-trip tests.

AC1: field_validator parses JSON-stringified info dicts back to dicts
AC2: TextualMemoryItem survives round-trip through JSON-stringified info
AC3: Verify MANGO-TANGO, PAPAYA-SUNSET, CRIMSON-FALCON recall via live MEMOS API
"""

import json
import pytest
import requests

from memos.memories.textual.item import TextualMemoryMetadata, TreeNodeTextualMemoryMetadata, TextualMemoryItem

MEMOS_BASE = "http://localhost:8001"
SEARCH_ENDPOINT = f"{MEMOS_BASE}/product/search"
TEST_USER_ID = "openclaw-user"


# ---------------------------------------------------------------------------
# AC1 — field_validator: JSON string → dict
# ---------------------------------------------------------------------------

class TestInfoFieldValidator:
    def test_plain_dict_passes_through(self):
        meta = TextualMemoryMetadata(info={"key": "value", "count": 42})
        assert meta.info == {"key": "value", "count": 42}

    def test_json_string_parsed_to_dict(self):
        """Core regression: Neo4j returns info as a JSON string."""
        raw = json.dumps({"key": "value", "count": 42})
        meta = TextualMemoryMetadata(info=raw)
        assert isinstance(meta.info, dict)
        assert meta.info == {"key": "value", "count": 42}

    def test_empty_json_object_string(self):
        meta = TextualMemoryMetadata(info="{}")
        assert meta.info == {}

    def test_invalid_json_string_returns_empty_dict(self):
        meta = TextualMemoryMetadata(info="not-valid-json{{{")
        assert meta.info == {}

    def test_json_array_string_returns_empty_dict(self):
        """Non-dict JSON (array) should not crash, returns empty dict."""
        meta = TextualMemoryMetadata(info='["a", "b"]')
        assert meta.info == {}

    def test_none_passes_through(self):
        meta = TextualMemoryMetadata(info=None)
        assert meta.info is None

    def test_nested_dict_in_json_string(self):
        payload = {"nested": {"x": 1}, "tags": ["a", "b"]}
        meta = TextualMemoryMetadata(info=json.dumps(payload))
        assert meta.info == payload

    def test_tree_node_metadata_inherits_validator(self):
        """TreeNodeTextualMemoryMetadata inherits from TextualMemoryMetadata — validator applies."""
        raw = json.dumps({"source": "neo4j-read", "version": 1})
        meta = TreeNodeTextualMemoryMetadata(info=raw)
        assert isinstance(meta.info, dict)
        assert meta.info["source"] == "neo4j-read"


# ---------------------------------------------------------------------------
# AC2 — Round-trip: TextualMemoryItem with stringified info survives from_dict
# ---------------------------------------------------------------------------

class TestTextualMemoryItemRoundTrip:
    def test_from_dict_with_stringified_info(self):
        info_payload = {"role": "assistant", "session": "abc123"}
        data = {
            "id": "00000000-0000-0000-0000-000000000001",
            "memory": "Test memory content",
            "metadata": {
                "user_id": "claw",
                "info": json.dumps(info_payload),  # Simulates Neo4j read
                "memory_type": "LongTermMemory",
            },
        }
        item = TextualMemoryItem.from_dict(data)
        assert item.memory == "Test memory content"
        assert isinstance(item.metadata.info, dict)
        assert item.metadata.info == info_payload

    def test_from_dict_without_info(self):
        data = {
            "id": "00000000-0000-0000-0000-000000000002",
            "memory": "Another memory",
            "metadata": {"user_id": "claw"},
        }
        item = TextualMemoryItem.from_dict(data)
        assert item.memory == "Another memory"
        assert item.metadata.info is None


# ---------------------------------------------------------------------------
# AC3 — Live MEMOS search: MANGO-TANGO, PAPAYA-SUNSET, CRIMSON-FALCON
# ---------------------------------------------------------------------------

RECALL_MARKERS = [
    "MANGO-TANGO",
    "PAPAYA-SUNSET",
    "CRIMSON-FALCON",
]

def _search(query: str) -> dict:
    resp = requests.post(
        SEARCH_ENDPOINT,
        json={"query": query, "user_id": TEST_USER_ID, "source": "test"},
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


@pytest.mark.live
@pytest.mark.parametrize("marker", RECALL_MARKERS)
def test_live_recall_marker(marker):
    """AC3: Each marker must be recalled with at least one result (relevance > 0.6)."""
    result = _search(marker)

    # Flatten all memory items from whichever response shape MEMOS returns
    memories = []
    if isinstance(result, dict):
        data = result.get("data", {})
        if isinstance(data, dict):
            # text_mem is a list of cube dicts, each with a "memories" list
            for cube in data.get("text_mem", []):
                memories.extend(cube.get("memories", []))
        if not memories:
            # Fallback: flat list shapes
            for key in ("memory_detail_list", "results", "memories"):
                if key in result and isinstance(result[key], list):
                    memories = result[key]
                    break
    elif isinstance(result, list):
        memories = result

    assert memories, (
        f"[AC3] Search for '{marker}' returned empty results. "
        f"Raw response: {json.dumps(result, indent=2)[:500]}"
    )

    # Check relevance if available — field is metadata.relativity in MEMOS
    def _get_relativity(m: dict) -> float:
        meta = m.get("metadata", {})
        return meta.get("relativity", m.get("relevance_score", m.get("score", 1.0)))

    has_scores = any(_get_relativity(m) != 1.0 for m in memories)
    if has_scores:
        scored = [m for m in memories if _get_relativity(m) > 0.6]
        assert scored, (
            f"[AC3] Search for '{marker}' returned results but none with relativity > 0.6. "
            f"Scores: {[_get_relativity(m) for m in memories]}"
        )
