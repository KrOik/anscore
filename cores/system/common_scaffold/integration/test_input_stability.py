"""Exercise regression provenance against changed and missing inputs."""
from pathlib import Path
import tempfile

from test_image_extensions import changed_files, snapshot_files


def main():
    with tempfile.TemporaryDirectory(prefix='extension_provenance_') as temporary:
        folder = Path(temporary)
        source, script, rom = folder/'core.v', folder/'test.py', folder/'log.hex'
        source.write_bytes(b'baseline RTL')
        script.write_bytes(b'baseline test')
        rom.write_bytes(b'0000\n0100\n')
        before = snapshot_files([source, script, rom])
        assert changed_files(before) == []
        script.write_bytes(b'changed test')
        assert changed_files(before) == [str(script.resolve())]
        script.write_bytes(b'baseline test')
        rom.write_bytes(b'0000\n0101\n')
        assert changed_files(before) == [str(rom.resolve())]
        rom.write_bytes(b'0000\n0100\n')
        source.unlink()
        assert changed_files(before) == [str(source.resolve())]
    print('INPUT_STABILITY PASS: unchanged, modified script/ROM, missing RTL; temp removed')


if __name__ == '__main__':
    main()
