# SPDX-License-Identifier: MIT
from collections import Counter, deque
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
HAS_UNICORN = importlib.util.find_spec("unicorn") is not None
if HAS_UNICORN:
    import mt7932_policy_reference as reference
    from unicorn import Uc, UC_ARCH_X86, UC_MODE_64, UC_HOOK_CODE, UC_HOOK_MEM_INVALID


@unittest.skipUnless(HAS_UNICORN, "optional native Unicorn test dependency")
class EmulatorBoundaryTests(unittest.TestCase):
    def machine(self, code, imported=None):
        machine = reference.Machine.__new__(reference.Machine)
        machine.image = SimpleNamespace(symbols={"entry": 0x100000}, name=lambda a: hex(a))
        machine.uc = Uc(UC_ARCH_X86, UC_MODE_64)
        machine.uc.mem_map(0x100000, 0x1000)
        machine.uc.mem_write(0x100000, code)
        machine.uc.mem_map(machine.STACK, machine.STACK_SIZE)
        machine.uc.mem_map(machine.STOP, 0x1000)
        machine.hooks = {0x100000: imported} if imported else {}
        machine.calls, machine.trace = Counter(), deque(maxlen=40)
        machine.uc.hook_add(UC_HOOK_CODE, machine.dispatch)
        machine.uc.hook_add(UC_HOOK_MEM_INVALID, machine.bad_memory)
        return machine

    def test_unknown_host_service_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "Unimplemented call _socket"):
            self.machine(b"\xc3", "_socket").call("entry")

    def test_syscall_cannot_escape_emulator(self):
        with self.assertRaisesRegex(RuntimeError, "System call attempted"):
            self.machine(b"\x0f\x05\xc3").call("entry")

    def test_unmapped_memory_stops_execution(self):
        with self.assertRaisesRegex(RuntimeError, "Unmapped memory"):
            self.machine(b"\x48\xa1" + bytes(8) + b"\xc3").call("entry")

    def test_instruction_budget_stops_nonreturning_code(self):
        with self.assertRaisesRegex(RuntimeError, "instruction/time budget"):
            self.machine(b"\xeb\xfe").call("entry", instructions=10)

    def test_returning_code_completes(self):
        self.assertEqual(self.machine(b"\xb8\x2a\x00\x00\x00\xc3").call("entry"), 42)


if __name__ == "__main__":
    unittest.main()
