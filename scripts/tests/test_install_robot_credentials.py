import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "installer", Path(__file__).parents[1] / "install_robot_credentials.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.source = root / "enrolled.env"
        self.source.write_text(
            "export ROBOT_ID=z2-001\n"
            f"export ROBOT_API_KEY=zrk1.{'a' * 32}.{'b' * 43}\n"
            "export ROBOT_BACKEND_URL=https://backend.example\n")
        self.source.chmod(0o600)
        self.target = root / "robot.env"
        self.original = (
            "# existing device settings\nDEVICE_NAME=robot\n"
            "TAILSCALE_AUTH_KEY=keep-this\nFOXGLOVE_DEVICE_TOKEN=keep-that\n"
            "OTHER_VALUE=literal$()\nROBOT_ID=old\nROBOT_API_KEY=old-key\n")
        self.target.write_text(self.original)

    def install(self):
        installer.install_credentials(self.source, self.target, os.getgid(), os.getuid())

    def test_preserves_settings_and_emits_docker_format_idempotently(self):
        self.install()
        content = self.target.read_text()
        self.assertIn("TAILSCALE_AUTH_KEY=keep-this\n", content)
        self.assertIn("FOXGLOVE_DEVICE_TOKEN=keep-that\n", content)
        self.assertIn("OTHER_VALUE=literal$()\n", content)
        self.assertNotIn("export ", content)
        self.assertEqual(content.count("ROBOT_ID="), 1)
        self.assertEqual(content.count("ROBOT_API_KEY="), 1)
        self.assertIn("ROBOT_ID=z2-001\n", content)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o640)
        self.install()
        self.assertEqual(content, self.target.read_text())

    def test_failed_atomic_replace_preserves_original(self):
        with patch.object(installer.os, "replace", side_effect=OSError("simulated failure")):
            with self.assertRaises(OSError):
                self.install()
        self.assertEqual(self.target.read_text(), self.original)
        self.assertFalse(list(self.target.parent.glob(".robot.env.*")))

    def test_rejects_invalid_source_without_changing_host_config(self):
        self.source.write_text("export ROBOT_ID=z2-001\n")
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(self.target.read_text(), self.original)

    def test_rejects_public_secret_file(self):
        self.source.chmod(0o644)
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(self.target.read_text(), self.original)

    def test_rejects_symlink_target(self):
        other = self.target.with_name("other.env")
        self.target.rename(other)
        self.target.symlink_to(other)
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(other.read_text(), self.original)


if __name__ == "__main__":
    unittest.main()
