"""Source contract checks without loading MLX or running inference."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('stem_worker', Path(__file__).resolve().parents[1] / 'worker/stem_worker.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)

class SourceContractTests(unittest.TestCase):
    def test_native_four_order_is_canonicalized(self):
        self.assertEqual(worker.canonical_sources(['drums', 'bass', 'other', 'vocals']), worker.SOURCES)

    def test_native_six_order_preserves_guitar_and_piano(self):
        self.assertEqual(worker.canonical_sources(['drums', 'bass', 'other', 'vocals', 'guitar', 'piano']), worker.SIX_SOURCES)

    def test_invalid_source_contracts_fail(self):
        for sources in ([], ['vocals'] * 4, worker.SOURCES + ['guitar'], worker.SOURCES + ['guitar', 'unknown']):
            with self.subTest(sources=sources), self.assertRaises(ValueError):
                worker.canonical_sources(sources)

if __name__ == '__main__':
    unittest.main()
