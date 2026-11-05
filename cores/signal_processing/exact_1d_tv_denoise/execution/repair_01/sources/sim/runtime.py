"""Static PE import closure and immutable tool/runtime byte guards; no launch."""
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import struct

VPI_NAMES = ('system.vpi', 'v2005_math.vpi', 'v2009.vpi', 'va_math.vpi',
             'vhdl_sys.vpi', 'vhdl_textio.vpi')
BACKEND_NAMES = ('ivl.exe', 'ivlpp.exe', 'null.tgt', 'vvp.tgt',
                 'null.conf', 'null-s.conf', 'vvp.conf', 'vvp-s.conf')


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pe_imports(path: Path) -> list[str]:
    """Read safe ordinary/delay import module basenames from PE bytes."""
    data = path.read_bytes()
    assert data[:2] == b'MZ' and len(data) >= 64, str(path)
    pe = struct.unpack_from('<I', data, 60)[0]
    assert data[pe:pe+4] == b'PE\0\0'
    sections, optional_bytes = struct.unpack_from('<H12xH', data, pe+6)
    optional = pe+24
    magic = struct.unpack_from('<H', data, optional)[0]
    assert magic in (0x10b, 0x20b)
    directory = optional+(112 if magic == 0x20b else 96)
    count_offset = optional+(108 if magic == 0x20b else 92)
    directory_count = struct.unpack_from('<I', data, count_offset)[0]
    image_base = struct.unpack_from('<Q' if magic == 0x20b else '<I', data,
                                    optional+(24 if magic == 0x20b else 28))[0]
    header_bytes = struct.unpack_from('<I', data, optional+60)[0]
    table = optional+optional_bytes
    assert 0 < sections < 128 and table+40*sections <= len(data)
    ranges = []
    for index in range(sections):
        virtual_size, virtual_address, raw_size, raw_offset = struct.unpack_from('<IIII', data, table+40*index+8)
        assert raw_offset+raw_size <= len(data)
        ranges.append((virtual_address, max(virtual_size, raw_size), raw_offset, raw_size))

    def offset(rva: int, size: int = 1) -> int:
        if 0 <= rva < header_bytes and rva+size <= min(header_bytes, len(data)):
            return rva
        for base, span, file_start, file_size in ranges:
            if base <= rva < base+span:
                delta = rva-base
                assert delta+size <= file_size, 'unbacked PE RVA'
                return file_start+delta
        raise AssertionError('PE RVA outside file-backed sections')

    def module_name(rva: int) -> str:
        begin = offset(rva)
        end = data.find(b'\0', begin, min(len(data), begin+512))
        assert end > begin
        value = data[begin:end].decode('ascii').lower()
        assert value.endswith(('.dll', '.exe', '.pyd'))
        assert all(c.isalnum() or c in '._-+' for c in value), 'unsafe PE module basename'
        return value

    names = set()
    for number, stride in ((1, 20), (13, 32)):
        if number >= directory_count:
            continue
        assert directory+8*(number+1) <= optional+optional_bytes
        rva, size = struct.unpack_from('<II', data, directory+8*number)
        if not rva:
            assert size == 0
            continue
        assert stride <= size < 1 << 20
        terminated = False
        for relative in range(0, size, stride):
            entry = offset(rva+relative, stride)
            fields = struct.unpack_from('<'+'I'*(stride//4), data, entry)
            if not any(fields):
                terminated = True
                break
            if number == 1:
                name_rva = fields[3]
            else:
                attributes, name_rva = fields[:2]
                assert attributes in (0, 1)
                if not attributes:
                    name_rva -= image_base
            names.add(module_name(name_rva))
        assert terminated, 'unterminated PE import table'
    return sorted(names)


def snapshot(tools: dict[str, str]) -> dict:
    assert os.name == 'nt', 'the finite plan uses a Windows Job Object runtime'
    paths = {key: Path(value).resolve(strict=True) for key, value in tools.items()}
    assert set(paths) == {'PYTHON', 'IVERILOG', 'VVP'}
    suite = paths['IVERILOG'].parent.parent
    assert paths['VVP'].parent == suite/'bin'
    ivl = suite/'lib/ivl'
    system = Path(os.environ['SystemRoot']).resolve(strict=True)/'System32'
    python_dlls = paths['PYTHON'].parent/'DLLs'
    search = list(dict.fromkeys([suite/'bin', suite/'lib', paths['PYTHON'].parent, python_dlls, system]))
    assert all(folder.is_dir() for folder in search)
    # Directory name inventories detect a new DLL that could shadow a sealed
    # import, while only the actual transitive closure is fingerprinted.
    directory_names = {str(folder): sorted(p.name.lower() for p in folder.iterdir()
                                          if p.is_file() and p.suffix.lower() in ('.dll', '.pyd'))
                       for folder in search+[ivl]}
    lookups = {str(folder): {p.name.lower(): p.resolve(strict=True) for p in folder.iterdir() if p.is_file()}
               for folder in search+[ivl]}
    backend = {str((ivl/name).resolve(strict=True)): sha(ivl/name) for name in BACKEND_NAMES}
    modules = {str((ivl/name).resolve(strict=True)): sha(ivl/name) for name in VPI_NAMES}
    python_extensions = {str(p.resolve(strict=True)): sha(p) for p in python_dlls.iterdir()
                         if p.is_file() and p.suffix.lower() == '.pyd'}
    assert python_extensions, 'Python extension runtime directory is empty'
    pending = list(paths.values())+[Path(name) for name in backend if Path(name).read_bytes()[:2] == b'MZ']
    pending += [Path(name) for name in modules]
    # Fraction/decimal/math/hashlib/ctypes can load PYD extensions dynamically.
    # Fingerprint all installed extension PEs and close their local imports;
    # Graph traversal reads PE bytes; it does not load these extension files.
    pending += [Path(name) for name in python_extensions]
    graph: dict[str, dict] = {}
    system_files: dict[str, str] = {}
    api_contracts = set()
    while pending:
        owner = pending.pop()
        key = str(owner)
        if key in graph:
            continue
        assert len(graph) < 256, 'bounded local PE closure'
        imports = pe_imports(owner)
        edges = {}
        owner_lookup = {p.name.lower(): p.resolve(strict=True) for p in owner.parent.iterdir() if p.is_file()}
        for name in imports:
            if name.startswith(('api-ms-win-', 'ext-ms-win-')):
                api_contracts.add(name)
                edges[name] = 'WINDOWS_API_SET_CONTRACT'
                continue
            candidates = [owner_lookup[name]] if name in owner_lookup else []
            candidates += [lookups[str(folder)][name] for folder in search if name in lookups[str(folder)]]
            assert candidates, (owner.name, 'unresolved DLL', name)
            dependency = candidates[0]
            edges[name] = str(dependency)
            if dependency.parent == system:
                system_files[str(dependency)] = sha(dependency)
            else:
                assert dependency.parent in search or dependency.parent == ivl
                pending.append(dependency)
        graph[key] = dict(sha256=sha(owner), imports=imports, resolved_imports=edges)
    return dict(schema='anscore-tv-static-pe-runtime-v1',
                tools={key: dict(path=str(path), sha256=sha(path)) for key, path in paths.items()},
                compiler_backend_sha256=backend, runtime_modules_sha256=modules,
                python_extensions_sha256=python_extensions,
                local_pe_graph=graph, windows_system_files_sha256=system_files,
                windows_api_set_contracts=sorted(api_contracts), dll_directory_names=directory_names,
                path_prefix=[str(suite/'bin'), str(suite/'lib'), str(paths['PYTHON'].parent), str(python_dlls), str(system)],
                resolution='owner directory then fixed bin/lib/Python/Python-DLLs/System32; Windows API sets delegated to the OS',
                compiler_or_numerical_launched=False)


def verify(record: dict) -> None:
    assert record['schema'] == 'anscore-tv-static-pe-runtime-v1'
    for tool in record['tools'].values():
        assert sha(Path(tool['path'])) == tool['sha256'], 'tool bytes changed'
    for field in ('compiler_backend_sha256', 'runtime_modules_sha256', 'python_extensions_sha256', 'windows_system_files_sha256'):
        for name, expected in record[field].items():
            assert sha(Path(name)) == expected, (field, name)
    for name, node in record['local_pe_graph'].items():
        assert sha(Path(name)) == node['sha256'], 'local PE bytes changed'
    for folder, names in record['dll_directory_names'].items():
        current = sorted(p.name.lower() for p in Path(folder).iterdir() if p.is_file() and p.suffix.lower() in ('.dll', '.pyd'))
        assert current == names, 'DLL search-directory names changed'
    assert all(Path(folder).is_dir() for folder in record['path_prefix'])
