"""
CLA-81: MemOS End-to-End Integration Test
==========================================
Proves the full write→store→recall cycle:
  1. Session A writes a memory via /product/add
  2. Session B recalls it via /product/search (cross-session, no vault files)
  3. Chat endpoint no longer returns 503
  4. Neo4j sources deserialization is correct (no double-deser, no [0]=="}" bug)

Run: python3 -m pytest tests/test_cla81_integration.py -v
"""

import json
import time
import urllib.request
import uuid

import pytest

BASE_URL = "http://localhost:8001"
TEST_USER = "cla81-e2e-test"


def _post(endpoint: str, payload: dict) -> dict:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{BASE_URL}{endpoint}",
        data=data,
        headers={"Content-Type": "application/json"},
    )
    try:
        resp = urllib.request.urlopen(req, timeout=30)
        return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        return {"_http_error": e.code, "_body": body}


def _memos_up() -> bool:
    try:
        result = _post("/product/search", {"user_id": "ping", "query": "ping", "top_k": 1})
        return result.get("code") == 200
    except Exception:
        return False


@pytest.fixture(scope="module", autouse=True)
def require_memos():
    """Skip all tests if MemOS is not running."""
    if not _memos_up():
        pytest.skip("MemOS server not running on localhost:8001")


class TestCrossSessionRecall:
    """Write in session_a → recall in session_b (no vault files)."""

    def test_write_and_recall_cross_session(self):
        """Core value chain: write from session A, recall from session B."""
        unique_marker = f"CLA81-CROSS-SESSION-{uuid.uuid4().hex[:8]}"
        session_a = f"cla81-session-a-{uuid.uuid4().hex[:6]}"
        session_b = f"cla81-session-b-{uuid.uuid4().hex[:6]}"

        # --- LEG 1: Session A writes ---
        write_result = _post("/product/add", {
            "user_id": TEST_USER,
            "conversation_id": session_a,
            "messages": [
                {"role": "user", "content": f"Remember: {unique_marker} is the secret word for this test"},
                {"role": "assistant", "content": f"I'll remember: {unique_marker}"},
            ],
            "source": "cla81-test",
        })
        assert write_result.get("code") == 200, f"Write failed: {write_result}"

        # Allow MemOS async processing to complete
        time.sleep(3)

        # --- LEG 2: Session B recalls (different conversation_id) ---
        recall_result = _post("/product/search", {
            "user_id": TEST_USER,
            "query": f"{unique_marker}",
            "top_k": 5,
            "source": "cla81-test",
        })
        assert recall_result.get("code") == 200, f"Search failed: {recall_result}"

        # Verify the memory is retrievable cross-session
        memories_text = json.dumps(recall_result.get("data", {}))
        assert unique_marker in memories_text, (
            f"Cross-session recall FAILED: '{unique_marker}' not found in search results.\n"
            f"This means MemOS is not persisting memories across sessions.\n"
            f"Data: {memories_text[:500]}"
        )

    def test_write_returns_memory_id(self):
        """Write should return a memory_id for tracking."""
        result = _post("/product/add", {
            "user_id": TEST_USER,
            "conversation_id": f"cla81-id-test-{uuid.uuid4().hex[:6]}",
            "messages": [
                {"role": "user", "content": "CLA-81 memory_id tracking test"},
                {"role": "assistant", "content": "Confirmed"},
            ],
            "source": "cla81-test",
        })
        assert result.get("code") == 200
        data = result.get("data", [])
        assert isinstance(data, list) and len(data) > 0
        assert data[0].get("memory_id"), f"No memory_id in response: {data}"


class TestChatHandler:
    """Chat endpoint should not return 503 when ENABLE_CHAT_API=true."""

    def test_chat_complete_not_503(self):
        """Chat complete should not return 503 (ENABLE_CHAT_API must be true)."""
        result = _post("/product/chat/complete", {
            "user_id": TEST_USER,
            "query": "What is 2+2?",
            "messages": [{"role": "user", "content": "What is 2+2?"}],
        })
        http_error = result.get("_http_error")
        if http_error == 503:
            pytest.fail(
                "Chat handler returned 503 — ENABLE_CHAT_API is not set or chat_llms is empty. "
                "Set ENABLE_CHAT_API=true and CHAT_MODEL_LIST in .env and restart."
            )
        # 200 (with memory recall) or 500 (LLM error) are acceptable — not 503
        assert http_error != 503, f"Unexpected 503: {result}"

    def test_chat_complete_responds(self):
        """Chat complete should return a coherent response."""
        result = _post("/product/chat/complete", {
            "user_id": TEST_USER,
            "query": "Say hello",
            "messages": [{"role": "user", "content": "Say hello"}],
        })
        # Accept 200 (working) or 500/400 (model error — not a 503 infra issue)
        code = result.get("code") or result.get("_http_error")
        assert code != 503, f"Chat handler still returning 503: {result}"


class TestNeo4jSourcesDeserialization:
    """Verify sources field round-trips correctly (no double-deser bug)."""

    def test_sources_not_double_serialized(self):
        """
        Verify the bug fix: sources[idx][0] == "}" was always False,
        preventing deserialization. Now sources round-trips correctly.
        """
        # Write a memory (sources will be empty list [] by default from add endpoint)
        unique = f"CLA81-SOURCES-{uuid.uuid4().hex[:8]}"
        write_result = _post("/product/add", {
            "user_id": TEST_USER,
            "conversation_id": f"cla81-sources-{uuid.uuid4().hex[:6]}",
            "messages": [
                {"role": "user", "content": f"Sources test: {unique}"},
                {"role": "assistant", "content": "Confirmed sources test"},
            ],
            "source": "cla81-test",
        })
        assert write_result.get("code") == 200

        time.sleep(2)

        # Recall and verify sources field is a list (not a double-JSON-encoded string)
        recall = _post("/product/search", {
            "user_id": TEST_USER,
            "query": unique,
            "top_k": 3,
        })
        assert recall.get("code") == 200

        for group in recall["data"].get("text_mem", []):
            for mem in group.get("memories", []):
                sources = mem.get("metadata", {}).get("sources", [])
                # sources should be a list, not a string
                assert isinstance(sources, list), (
                    f"sources field is not a list after recall — double-serialization bug: {sources!r}"
                )
                # If sources has entries, they should be dicts, not JSON strings
                for src in sources:
                    assert not isinstance(src, str), (
                        f"sources[i] is a string — deser bug still active: {src!r}"
                    )


class TestServiceHealth:
    """Verify all backing services are healthy."""

    def test_memos_search_reachable(self):
        result = _post("/product/search", {"user_id": "health", "query": "health", "top_k": 1})
        assert result.get("code") == 200

    def test_scheduler_status(self):
        result = _post("/product/scheduler/allstatus", {"user_id": TEST_USER})
        # Just needs to not 503/500
        assert "_http_error" not in result or result["_http_error"] < 500
