"""Integration & Contract Tests for API & MCP Server."""

import sys
import unittest
from pathlib import Path
from fastapi.testclient import TestClient

# Add src to sys.path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from c_drive_savior.server.api_server import app
from c_drive_savior.server.mcp_server import handle_tool_call


class ApiServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.client = TestClient(app)

    def test_get_known_folders_endpoint(self):
        resp = self.client.get("/api/known-folders")
        self.assertEqual(resp.status_code, 200)
        data = resp.json()
        self.assertIn("Documents", data)
        self.assertIn("Downloads", data)

    def test_get_overview_endpoint(self):
        resp = self.client.get("/api/overview")
        self.assertEqual(resp.status_code, 200)
        data = resp.json()
        self.assertIn("c_drive", data)
        self.assertIn("discovered_items", data)
        self.assertIsInstance(data["discovered_items"], list)

    def test_console_static_serve(self):
        resp = self.client.get("/")
        self.assertEqual(resp.status_code, 200)
        self.assertIn("C-Drive-Savior", resp.text)


class McpServerTests(unittest.TestCase):
    def test_mcp_get_known_folders_call(self):
        result = handle_tool_call("get_known_folders", {})
        self.assertIn("Documents", result)
        self.assertIn("Downloads", result)

    def test_mcp_get_overview_call(self):
        result = handle_tool_call("get_c_drive_overview", {})
        self.assertIn("session_id", result)
        self.assertIn("c_drive", result)
        self.assertIn("top_consumers", result)


if __name__ == "__main__":
    unittest.main()
