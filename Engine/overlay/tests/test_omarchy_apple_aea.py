# SPDX-License-Identifier: MIT
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
import omarchy_apple_aea as aea  # noqa: E402


class DecryptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'image.dmg.aea'
        self.source.write_bytes(b'AEA1 archive')
        self.destination = self.root / 'image.dmg'
        self.commands = []

    def run_decoder(self, command, check):
        self.assertTrue(check)
        self.commands.append(command)
        Path(command[3]).write_bytes(b'plain')

    def test_the_decoder_gets_the_archive_and_its_digest(self):
        aea.decrypt(self.source, self.destination, run=self.run_decoder)
        self.assertEqual(self.commands, [[
            str(aea.DECODER), str(self.source),
            hashlib.sha256(b'AEA1 archive').hexdigest(), str(self.destination),
        ]])
        self.assertEqual(self.destination.read_bytes(), b'plain')

    def test_an_existing_destination_is_never_overwritten(self):
        self.destination.write_bytes(b'keep')
        with self.assertRaisesRegex(aea.AppleInputError, 'already exists'):
            aea.decrypt(self.source, self.destination, run=self.run_decoder)
        self.assertEqual(self.commands, [])
        self.assertEqual(self.destination.read_bytes(), b'keep')

    def test_a_decoder_that_writes_nothing_is_an_error(self):
        with self.assertRaisesRegex(aea.AppleInputError, 'wrote no image.dmg'):
            aea.decrypt(self.source, self.destination, run=lambda command, check: None)


class RecipeTests(unittest.TestCase):
    def test_the_bundled_recipe_pins_the_25g83_radio_inputs(self):
        recipe = json.loads(aea.recipe())
        self.assertIn('25G83', recipe['source']['url'])
        names = {entry['name'] for entry in recipe['files']}
        for name in ('sunrise/IZUBA_W7932_2.bin', 'sunrise/IZUBA_wifi.cfg',
                     'bluetooth/MT7932_PTB_IzubaA_0.1.0.0_20251021141303.ptx'):
            self.assertIn(name, names)

    def test_a_damaged_recipe_is_refused(self):
        original = aea.RECIPE
        aea.RECIPE = original.replace('e', 'f', 1)
        self.addCleanup(setattr, aea, 'RECIPE', original)
        with self.assertRaisesRegex(aea.AppleInputError, 'damaged'):
            aea.recipe()


class NeoRadioRootTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.factory = Path(self.temporary.name) / 'FactoryData'
        self.factory.mkdir()
        self.commands = []

    def fetch(self, prefixes):
        def run(command, check):
            self.assertTrue(check)
            self.commands.append(command)
            self.assertEqual(Path(command[2]).read_bytes(), aea.recipe())
            for prefix in prefixes:
                (Path(command[4]) / prefix).mkdir(parents=True)
                (Path(command[4]) / prefix / 'file.bin').write_bytes(prefix.encode())
        return run

    def test_fetched_files_land_where_the_collector_reads_them(self):
        with aea.neo_radio_root(run=self.fetch(('sunrise', 'bluetooth', 'camera')),
                                factory_data=str(self.factory)) as root:
            self.assertEqual(Path(root, aea.IZUBA, 'file.bin').read_bytes(), b'sunrise')
            self.assertEqual(Path(root, aea.BLUETOOTH, 'file.bin').read_bytes(), b'bluetooth')
            self.assertEqual(os.readlink(Path(root, aea.FACTORY_DATA)), str(self.factory))
        self.assertEqual(self.commands[0][:2], [str(aea.DECODER), 'firmware-ranges'])
        self.assertEqual(self.commands[0][3], aea.RECIPE_SHA256)
        self.assertFalse(Path(root).exists())

    def test_a_fetch_without_bluetooth_files_is_refused(self):
        with self.assertRaisesRegex(aea.AppleInputError, 'no bluetooth files'):
            with aea.neo_radio_root(run=self.fetch(('sunrise',)), factory_data=str(self.factory)):
                pass


if __name__ == '__main__':
    unittest.main()
