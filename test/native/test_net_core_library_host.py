"""Compile the production Swift loader and exercise real dyld image lifetimes.

Run on macOS: python3 test/native/test_net_core_library_host.py
"""

from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == "Darwin", "macOS dyld regression")
class NetCoreLibraryHostTest(unittest.TestCase):
    def test_file_replacement_and_duplicate_images_keep_original_host(self):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory(prefix="fluxdo-library-host-") as directory:
            work = Path(directory)
            source = work / "fixture.c"
            source.write_text(
                "static int detached;\n"
                "void fluxdo_net_detach_host(void) { detached++; }\n"
                "int fluxdo_test_detach_count(void) { return detached; }\n"
            )
            library = work / "libfluxdo_net.dylib"
            subprocess.run(
                ["xcrun", "clang", "-dynamiclib", str(source), "-o", str(library)],
                check=True,
            )
            second = work / "second.dylib"
            shutil.copy2(library, second)
            executable = work / "host-test"
            subprocess.run(
                [
                    "xcrun", "swiftc",
                    str(root / "macos/Runner/NetCoreLibraryHost.swift"),
                    str(root / "test/native/net_core_library_host_test.swift"),
                    "-o", str(executable),
                ],
                check=True,
            )
            result = subprocess.run(
                [str(executable), str(library), str(second)],
                check=True, capture_output=True, text=True,
            )
            self.assertIn("PASS:", result.stdout)
            print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
