"""
Tests for TabCircle helper configuration loading and precedence.
"""

import sys
import os
import json
import tempfile
import unittest

# Ensure linux-helper is importable
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(PROJECT_ROOT, "linux-helper"))

import app

class TestConfigPrecedence(unittest.TestCase):
    def setUp(self):
        self.tmp_config = os.path.join(tempfile.gettempdir(), "test_tabcircle_config.json")
        self.old_config_file = app.CONFIG_FILE
        app.CONFIG_FILE = self.tmp_config
        self.sys_argv_backup = list(sys.argv)
        sys.argv = [a for a in sys.argv if a not in ("--low-resource", "--no-low-resource")]

    def tearDown(self):
        app.CONFIG_FILE = self.old_config_file
        sys.argv = self.sys_argv_backup
        if os.path.exists(self.tmp_config):
            try:
                os.remove(self.tmp_config)
            except OSError:
                pass

    def test_default_without_config_is_false(self):
        if os.path.exists(self.tmp_config):
            os.remove(self.tmp_config)
        cfg = app.load_helper_config()
        self.assertFalse(cfg["low_resource_mode"])

    def test_config_file_enables_mode(self):
        with open(self.tmp_config, "w", encoding="utf-8") as f:
            json.dump({"low_resource_mode": True}, f)
        cfg = app.load_helper_config()
        self.assertTrue(cfg["low_resource_mode"])

    def test_cli_flag_overrides_config_file_false(self):
        with open(self.tmp_config, "w", encoding="utf-8") as f:
            json.dump({"low_resource_mode": False}, f)
        sys.argv.append("--low-resource")
        cfg = app.load_helper_config()
        self.assertTrue(cfg["low_resource_mode"])

    def test_cli_flag_overrides_config_file_true(self):
        with open(self.tmp_config, "w", encoding="utf-8") as f:
            json.dump({"low_resource_mode": True}, f)
        sys.argv.append("--no-low-resource")
        cfg = app.load_helper_config()
        self.assertFalse(cfg["low_resource_mode"])

    def test_malformed_config_falls_back_safely(self):
        with open(self.tmp_config, "w", encoding="utf-8") as f:
            f.write("{ invalid json")
        cfg = app.load_helper_config()
        self.assertFalse(cfg["low_resource_mode"])

if __name__ == "__main__":
    unittest.main()
