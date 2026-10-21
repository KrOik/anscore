"""Verify frozen sensor inputs and compile with the registered extension bundle.

This is source-closure/compile evidence, not functional or board acceptance.
Does not alter the live regression registry or create binary build products.
"""
import hashlib
import json
from pathlib import Path
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    folder = evidence_dir('sensor_extensions_preflight')
    records = {}
    checked = {}
    sources = []
    for name in ('hx711_adc', 'ds3231_rtc', 'ads1115_adc', 'sht3x_sensor',
                 'camera_register_sequencer'):
        base = PACKAGE / 'peripherals' / name
        freeze = base / 'source_freeze.json'
        inputs = json.loads(freeze.read_text(encoding='utf-8'))
        for relative, expected in inputs.items():
            path = (base / relative).resolve()
            if not path.is_relative_to(base.resolve()) or digest(path) != expected:
                raise RuntimeError('frozen input mismatch: ' + str(path))
            checked[path] = expected
        checked[freeze] = digest(freeze)
        dependencies = {}
        for filename in ('dependency_sha256.json', 'dependencies.json'):
            dependency = base / filename
            if dependency.exists():
                if filename not in inputs:
                    raise RuntimeError('dependency manifest missing from freeze')
                for key, value in json.loads(dependency.read_text(encoding='utf-8')).items():
                    if key in dependencies and dependencies[key] != value:
                        raise RuntimeError('conflicting dependency hashes')
                    dependencies[key] = value
        for relative, expected in dependencies.items():
            path = (PACKAGE / relative).resolve()
            if not path.is_relative_to(PACKAGE.resolve()) or digest(path) != expected:
                raise RuntimeError('dependency mismatch: ' + str(path))
            checked[path] = expected
        primary = base / (name + '.sv')
        if primary.name not in inputs:
            raise RuntimeError('primary RTL missing from freeze')
        sources.append(primary)
        records[name] = {'source_freeze_sha256': digest(freeze),
                         'inputs': inputs, 'dependencies': dependencies}
    bundle = PACKAGE / 'rtl_extension_sources.f'
    checked[bundle] = digest(bundle)
    registered_sources = {}
    for line in bundle.read_text(encoding='utf-8').splitlines():
        relative = line.strip()
        if not relative or relative.startswith('#'):
            continue
        path = (ROOT / relative).resolve()
        if not path.is_relative_to(ROOT.resolve()) or path.suffix not in {'.v', '.sv'}:
            raise RuntimeError('unsupported bundle entry: ' + relative)
        checked[path] = digest(path)
        registered_sources[relative] = checked[path]
    execute(['iverilog', '-g2012', '-tnull', '-f', bundle, *sources],
            ROOT, folder / 'compile.log', timeout=120)
    for path, expected in checked.items():
        if digest(path) != expected:
            raise RuntimeError('input changed during compile: ' + str(path))
    write_json(folder / 'results.json', {
        'status': 'PASS', 'scope': 'frozen inputs and combined compile only',
        'registered_bundle_sha256': digest(bundle), 'sensors': records,
        'registered_source_sha256': registered_sources,
        'compile_log_sha256': digest(folder / 'compile.log'),
        'input_stability': 'PASS',
        'script_sha256': digest(Path(__file__)),
        'board_tested': False})
    print('PASS ' + str(folder))


if __name__ == '__main__':
    main()
