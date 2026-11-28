"""Identify the published Dart function at the recorded Windows fault."""
import struct
from pathlib import Path


original = Path('build/windows/x64/runner/Release/data/app.so').read_bytes()
code = Path('build/windows/app.so').read_bytes()
sections_start = struct.unpack_from('<Q', code, 40)[0]
entry_size, section_count, section_names = struct.unpack_from('<HHH', code, 58)
sections = [struct.unpack_from('<IIQQQQIIQQ', code, sections_start + i * entry_size)
            for i in range(section_count)]


def name(start):
    return code[start:code.index(b'\0', start)].decode(errors='replace')


by_name = {name(sections[section_names][4] + section[0]): section for section in sections}
symbols = by_name['.symtab']
strings = sections[symbols[6]][4]
for radius in (24, 16, 12, 8):
    fault = 0x1069cd9
    snippet = original[fault - radius:fault + radius]
    offset = code.find(snippet)
    if offset < 0 or code.find(snippet, offset + 1) != -1:
        continue
    pc = offset + radius
    for cursor in range(symbols[4], symbols[4] + symbols[5], symbols[9]):
        label, info, _, _, address, size = struct.unpack_from('<IBBHQQ', code, cursor)
        if info & 15 == 2 and address <= pc < address + size:
            print('Recorded reader frame:', name(strings + label), 'offset', hex(pc - address))
    break
