# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Bartosz Nitka
"""Offline stock serializers, adapted from nixos-neo's qualified converter.

Only the hash-pinned local executable is accepted. No device or network I/O is
provided to the emulated code. Unknown imports, syscalls, memory faults and
instruction/time budget exhaustion stop conversion.
"""
from bisect import bisect_right
from collections import Counter, deque
import hashlib
import re
import struct

from unicorn import (Uc, UC_ARCH_X86, UC_MODE_64, UC_HOOK_CODE, UC_HOOK_BLOCK,
                     UC_HOOK_MEM_INVALID, UC_PROT_ALL)
from unicorn.x86_const import (UC_X86_REG_RDI, UC_X86_REG_RSI, UC_X86_REG_RDX,
                              UC_X86_REG_RCX, UC_X86_REG_R8, UC_X86_REG_R9,
                              UC_X86_REG_RSP, UC_X86_REG_RBP, UC_X86_REG_RAX,
                              UC_X86_REG_RIP)

DIGEST = "5eb5587a310775efde276054d73f3827e79b61434a62c8e64d9a96208ebff007"


def require(condition, message):
    if not condition:
        raise ValueError(message)


class Image:
    def __init__(self, data):
        require(hashlib.sha256(data).hexdigest() == DIGEST,
                "Unrecognized AppleSunriseWLAN executable; expected macOS 26.6.2/25G83")
        magic, count = struct.unpack_from(">II", data)
        require(magic == 0xcafebabe and count == 2, "Unexpected universal executable")
        for i in range(count):
            cpu, subtype, offset, size, align = struct.unpack_from(">IIIII", data, 8 + i * 20)
            if cpu == 0x01000007:
                self.data = data[offset:offset + size]
                break
        else:
            raise ValueError("No x86_64 reference slice")
        header = struct.unpack_from("<8I", self.data)
        require(header[0] == 0xfeedfacf, "Unexpected Mach-O slice")
        self.segments, self.sections = [], []
        at = 32
        for _ in range(header[4]):
            cmd, size = struct.unpack_from("<II", self.data, at)
            if cmd == 0x19:
                (_, _, name, addr, length, off, nbytes, _, prot,
                 nsects, _) = struct.unpack_from("<II16sQQQQiiII", self.data, at)
                self.segments.append(dict(name=name.rstrip(b"\0").decode(), addr=addr,
                                          size=length, offset=off, bytes=nbytes, prot=prot))
                for i in range(nsects):
                    fields = struct.unpack_from("<16s16sQQ8I", self.data, at + 72 + i * 80)
                    self.sections.append(dict(name=fields[0].rstrip(b"\0").decode(),
                                              addr=fields[2], size=fields[3], offset=fields[4],
                                              flags=fields[8], reserved1=fields[9], reserved2=fields[10]))
            elif cmd == 2:
                _, _, symoff, nsyms, stroff, strsize = struct.unpack_from("<6I", self.data, at)
            elif cmd == 0xb:
                dysym = struct.unpack_from("<20I", self.data, at)
            elif cmd == 0x80000034:
                self.fixups_offset, self.fixups_size = struct.unpack_from("<II", self.data, at + 8)
            at += size
        self.symbols, self.symbol_list = {}, []
        for i in range(nsyms):
            name, kind, section, desc, value = struct.unpack_from("<IBBHQ", self.data, symoff + i * 16)
            name = self.data[stroff + name:].split(b"\0", 1)[0].decode()
            self.symbol_list.append(name)
            if value and kind & 0xe == 0xe:
                self.symbols[name] = value
        self.address_names = {v: k for k, v in self.symbols.items()}
        self.addresses = sorted(self.address_names)
        self.indirect = struct.unpack_from("<" + "I" * dysym[15], self.data, dysym[14])

    def name(self, address):
        i = bisect_right(self.addresses, address) - 1
        if i < 0:
            return hex(address)
        base = self.addresses[i]
        return self.address_names[base] + (f"+0x{address-base:x}" if base != address else "")


class Machine:
    HEAP, HEAP_SIZE = 0x200000000, 0x10000000
    STACK, STACK_SIZE = 0x300000000, 0x200000
    IMPORTS, STOP = 0x400000000, 0x500000000
    REGS = (UC_X86_REG_RDI, UC_X86_REG_RSI, UC_X86_REG_RDX,
            UC_X86_REG_RCX, UC_X86_REG_R8, UC_X86_REG_R9)

    def __init__(self, image, assets):
        self.image = image
        self.uc = Uc(UC_ARCH_X86, UC_MODE_64)
        self.hooks, self.imports, self.allocations = {}, {}, {}
        self.cursor = self.HEAP
        self.calls, self.commands, self.trace = Counter(), [], deque(maxlen=40)
        self.asset_requests = Counter()
        self.assets = assets
        self.failure = None
        for segment in image.segments:
            if segment["name"] == "__PAGEZERO" or not segment["size"]:
                continue
            self.uc.mem_map(segment["addr"], (segment["size"] + 0xfff) & ~0xfff, UC_PROT_ALL)
            self.uc.mem_write(segment["addr"], image.data[segment["offset"]:segment["offset"] + segment["bytes"]])
        for address, size in ((self.HEAP, self.HEAP_SIZE), (self.STACK, self.STACK_SIZE),
                              (self.IMPORTS, 0x100000), (self.STOP, 0x1000)):
            self.uc.mem_map(address, size, UC_PROT_ALL)
        self.uc.mem_write(self.STOP, b"\xf4")
        self.fixups()
        for section in image.sections:
            if section["flags"] & 0xff == 8:
                for at in range(0, section["size"], section["reserved2"]):
                    index = image.indirect[section["reserved1"] + at // section["reserved2"]]
                    if index < len(image.symbol_list):
                        self.hooks[section["addr"] + at] = image.symbol_list[index]
        names = ("___kalMemAlloc", "___kalMemFree", "_cnmMemAlloc", "__cnmMemFree", "_kalOsLog",
                 "_kalGetBootTime", "_kalGetThreadId", "_request_firmware", "_release_firmware",
                 "_kalFirmwareLoadByOffset", "_wlanSendSetQueryCmd", "_kalIoctlByBssIdx",
                 "_kalApplyCustomRegulatory")
        for name in names:
            if name in image.symbols:
                self.hooks[image.symbols[name]] = name
        self.uc.hook_add(UC_HOOK_CODE, self.dispatch)
        self.uc.hook_add(UC_HOOK_BLOCK, lambda u, a, n, d: self.trace.append(a))
        self.uc.hook_add(UC_HOOK_MEM_INVALID, self.bad_memory)
        if "_aucDebugModule" in image.symbols:
            self.uc.mem_write(image.symbols["_aucDebugModule"], bytes(64))
        if "_g_ucPrivacyLevel" in image.symbols:
            self.uc.mem_write(image.symbols["_g_ucPrivacyLevel"], bytes(1))

    def import_address(self, name):
        if name not in self.imports:
            address = self.IMPORTS + len(self.imports) * 32
            self.imports[name] = address
            self.hooks[address] = name
            self.uc.mem_write(address, b"\xc3" + bytes(15))
        return self.imports[name]

    def fixups(self):
        image = self.image
        data = image.data[image.fixups_offset:image.fixups_offset + image.fixups_size]
        version, starts, imports, strings, count, fmt, strfmt = struct.unpack_from("<7I", data)
        require(version == strfmt == 0 and fmt in (1, 2, 3), "Unsupported fixups")
        names = []
        for i in range(count):
            if fmt in (1, 2):
                value = struct.unpack_from("<I", data, imports + i * (4 if fmt == 1 else 8))[0]
                off = value >> 9
            else:
                value = struct.unpack_from("<Q", data, imports + i * 16)[0]
                off = value >> 32
            names.append(data[strings + off:].split(b"\0", 1)[0].decode())
        nsegments = struct.unpack_from("<I", data, starts)[0]
        for i in range(nsegments):
            info = struct.unpack_from("<I", data, starts + 4 + i * 4)[0]
            if not info:
                continue
            at = starts + info
            size, page_size, pointer_format, segment_offset, max_valid, pages = struct.unpack_from("<IHHQIH", data, at)
            require(pointer_format in (2, 6), "Unsupported fixup pointer")
            for page in range(pages):
                first = struct.unpack_from("<H", data, at + 22 + page * 2)[0]
                if first == 0xffff:
                    continue
                require(not first & 0x8000, "Unsupported chained fixup")
                address = 0x100000000 + segment_offset + page * page_size + first
                while True:
                    raw = self.u64(address)
                    next_offset = (raw >> 51) & 0xfff
                    if raw >> 63:
                        name = names[raw & 0xffffff]
                        value = self.import_address(name)
                        addend = (raw >> 24) & 0xff
                        value += addend if addend < 128 else addend - 256
                    else:
                        value = raw & ((1 << 36) - 1)
                        value |= ((raw >> 36) & 0xff) << 56
                        if pointer_format == 6:
                            value += 0x100000000
                    self.put64(address, value)
                    if not next_offset:
                        break
                    address += next_offset * 4

    def allocate(self, size):
        require(0 <= size <= 32 * 1024**2, "Invalid allocation")
        at = self.cursor
        self.cursor += (max(size, 1) + 15) & ~15
        require(self.cursor <= self.HEAP + self.HEAP_SIZE, "Heap budget exhausted")
        self.allocations[at] = size
        return at

    def buffer(self, data):
        at = self.allocate(len(data))
        self.uc.mem_write(at, data)
        return at

    def read(self, address, size):
        require(0 <= size <= 32 * 1024**2, "Read budget exceeded")
        return bytes(self.uc.mem_read(address, size))

    def cstring(self, address, maximum=32 * 1024**2):
        out = bytearray()
        while len(out) < maximum:
            part = self.read(address + len(out), min(256, maximum - len(out)))
            if b"\0" in part:
                return bytes(out) + part.split(b"\0", 1)[0]
            out.extend(part)
        raise ValueError("Unterminated string")

    def u64(self, address):
        return struct.unpack("<Q", self.read(address, 8))[0]

    def put64(self, address, value):
        self.uc.mem_write(address, struct.pack("<Q", value & ((1 << 64) - 1)))

    def put32(self, address, value):
        self.uc.mem_write(address, struct.pack("<I", value & 0xffffffff))

    def ret(self, value=0):
        sp = self.uc.reg_read(UC_X86_REG_RSP)
        target = self.u64(sp)
        self.uc.reg_write(UC_X86_REG_RAX, value & ((1 << 64) - 1))
        self.uc.reg_write(UC_X86_REG_RSP, sp + 8)
        self.uc.reg_write(UC_X86_REG_RIP, target)

    def argument(self, index):
        if index < 6:
            return self.uc.reg_read(self.REGS[index])
        return self.u64(self.uc.reg_read(UC_X86_REG_RSP) + 8 + (index - 6) * 8)

    def dispatch(self, uc, address, size, user):
        if address not in self.hooks:
            if self.read(address, min(size, 2)) == b"\x0f\x05":
                self.failure = RuntimeError("System call attempted")
                uc.emu_stop()
            return
        name = self.hooks[address]
        self.calls[name] += 1
        a, b, c, d, e, f = [self.argument(i) for i in range(6)]
        try:
            value = 0
            if name in ("___kalMemAlloc", "_malloc", "_IOMalloc", "_IOMallocTyped"):
                value = self.allocate(a)
            elif name == "_cnmMemAlloc":
                value = self.allocate(c)
            elif name in ("___kalMemFree", "__cnmMemFree", "_free", "_release_firmware", "_kalOsLog",
                          "_kalApplyCustomRegulatory"):
                pass
            elif name in ("_kalGetBootTime", "_kalGetThreadId"):
                value = 1
            elif name in ("_memcpy", "_memmove", "___memcpy_chk", "___memmove_chk"):
                require(not name.endswith("_chk") or c <= d, "Copy exceeds destination")
                self.uc.mem_write(a, self.read(b, c))
                value = a
            elif name in ("_memset", "___memset_chk"):
                require(c <= 32 * 1024**2, "Write budget exceeded")
                require(not name.endswith("_chk") or c <= d, "Write exceeds destination")
                self.uc.mem_write(a, bytes([b & 255]) * c)
                value = a
            elif name in ("_bzero", "___bzero"):
                require(b <= 32 * 1024**2, "Zero budget exceeded")
                self.uc.mem_write(a, bytes(b))
            elif name == "_strlen":
                value = len(self.cstring(a))
            elif name == "_strnlen":
                value = len(self.read(a, b).split(b"\0", 1)[0])
            elif name in ("_strcmp", "_strncmp", "_memcmp"):
                if name == "_memcmp":
                    aa, bb = self.read(a, c), self.read(b, c)
                elif name == "_strncmp":
                    aa, bb = self.read(a, c).split(b"\0", 1)[0], self.read(b, c).split(b"\0", 1)[0]
                else:
                    aa, bb = self.cstring(a), self.cstring(b)
                value = (aa > bb) - (aa < bb)
            elif name in ("_strchr", "_strrchr"):
                data = self.cstring(a) + b"\0"
                at = data.find(bytes([b & 255])) if name == "_strchr" else data.rfind(bytes([b & 255]))
                value = a + at if at >= 0 else 0
            elif name == "_strstr":
                at = self.cstring(a).find(self.cstring(b))
                value = a + at if at >= 0 else 0
            elif name in ("_strncpy", "___strncpy_chk"):
                require(c <= 32 * 1024**2, "String copy budget exceeded")
                require(not name.endswith("_chk") or c <= d, "String exceeds destination")
                data = self.cstring(b)[:c]
                self.uc.mem_write(a, data + bytes(c - len(data)))
                value = a
            elif name in ("_strtol", "_strtoul", "_strtoll", "_strtoull", "_atoi"):
                text = self.cstring(a).decode("ascii")
                base = 10 if name == "_atoi" else c
                match = re.match(r"\s*[+-]?(?:0[xX][0-9a-fA-F]+|[0-9]+)", text)
                token = match.group() if match else ""
                if token:
                    number = token.strip().lstrip("+-")
                    if not base:
                        base = 16 if number.lower().startswith("0x") else 8 if number.startswith("0") else 10
                    value = int(token, base)
                if name != "_atoi" and b:
                    self.put64(b, a + len(token))
            elif name == "_request_firmware":
                filename = self.cstring(b).decode()
                self.asset_requests[filename] += 1
                data = self.assets.get(filename)
                require(data is not None, "Unprovided original asset: " + filename)
                data_address = self.buffer(data + b"\0")
                fw = self.buffer(struct.pack("<QQQ", len(data), data_address, 0))
                self.put64(a, fw)
            elif name == "_kalFirmwareLoadByOffset":
                length, source = self.u64(a), self.u64(a + 8)
                amount = min(c, max(0, length - d))
                self.put32(e, amount)
                if amount:
                    self.uc.mem_write(b, self.read(source + d, amount))
                else:
                    value = 1
            elif name == "_wlanSendSetQueryCmd":
                length, source = self.argument(7), self.argument(8)
                require(0 < length <= 16384 and len(self.commands) < 15, "Command budget exceeded")
                self.commands.append(dict(cid=b, set=c, reply=d, payload=self.read(source, length)))
            elif name == "_kalIoctlByBssIdx":
                require(b == self.image.symbols["_wlanoidSetChipConfig"] and d == 328,
                        "Unexpected ioctl target")
                require(self.u64(a + 0x84270) == self.adapter, "Unexpected ioctl adapter")
                for reg, val in zip(self.REGS, (self.adapter, c, d, self.argument(7))):
                    self.uc.reg_write(reg, val)
                self.uc.reg_write(UC_X86_REG_RIP, b)
                return
            else:
                raise RuntimeError("Unimplemented call " + name)
            self.ret(value)
        except Exception as error:
            self.failure = error
            uc.emu_stop()

    def bad_memory(self, uc, access, address, size, value, user):
        self.failure = RuntimeError(f"Unmapped memory {access} at {address:x}+{size:x}")
        return False

    def call(self, name, *args, instructions=10000000):
        self.failure = None
        sp = self.STACK + self.STACK_SIZE - 0x108
        self.put64(sp, self.STOP)
        self.uc.reg_write(UC_X86_REG_RSP, sp)
        self.uc.reg_write(UC_X86_REG_RBP, 0)
        for i, value in enumerate(args):
            if i < 6:
                self.uc.reg_write(self.REGS[i], value)
            else:
                self.put64(sp + 8 + (i - 6) * 8, value)
        try:
            self.uc.emu_start(self.image.symbols[name], self.STOP,
                              timeout=60 * 1000000, count=instructions)
        except Exception as error:
            if self.failure is None:
                self.failure = error
        if self.failure is not None or self.uc.reg_read(UC_X86_REG_RIP) != self.STOP:
            trace = ", ".join(self.image.name(a) for a in self.trace)
            raise RuntimeError(f"{name}: {self.failure or 'instruction/time budget'}; trace={trace}")
        return self.uc.reg_read(UC_X86_REG_RAX)


def generate(image, assets):
    """Run the stock 00-to-XZ selection and 2.4/5 GHz serializers only."""
    m = Machine(image, assets)
    adapter = m.allocate(0x220000)
    m.adapter = adapter
    wiphy = m.allocate(0x85000 + 0x38)
    glue = wiphy + 0x38
    wdev = m.buffer(struct.pack("<Q", wiphy))
    m.put64(image.symbols["_gprWdev"], wdev)
    chip = image.symbols["_mt66xx_chip_info_mt7932"]
    m.put64(adapter + 0x118, chip)
    m.put64(adapter + 0x12b88, glue)
    m.put64(glue + 0x84270, adapter)
    m.put64(chip + 0x130, m.buffer(b"TxPwrLimit_MT79x1.dat\0"))
    m.put64(image.symbols["_g_mtk_regd_control"] + 0x10, glue)
    m.uc.mem_write(adapter + 0x11463d, b"\0")  # no 6 GHz channel capability
    selected = m.call("_rlmDomainUpdateRegdomainFromaLocalDataBaseByCountryCode",
                      wiphy, int.from_bytes(b"00", "little"), 0)
    require(selected == int.from_bytes(b"XZ", "little"), "Stock database did not select XZ")
    m.put32(image.symbols["_g_mtk_regd_control"] + 8, selected)
    m.put32(image.symbols["_g_dale80211_country_info"] + 0x3228, 1)
    m.call("_rlmDomainSendPwrLimitCmd_V2", adapter, instructions=100000000)
    return m.commands
