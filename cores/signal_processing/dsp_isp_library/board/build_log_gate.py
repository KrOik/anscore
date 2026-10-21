"""Reject known structural/clock failures before any physical programming."""
import re
from pathlib import Path

BAD = re.compile(r'warning:.*(?:logic loop|combinational loop|combinatorial loop|latch inferred)|no clocks found|unconstrained clock', re.I)

def assert_clean_build(build):
    build=Path(build)
    failures=[]
    logs=list(build.glob('*.log'))
    if not logs:raise ValueError('No build logs available for structural review')
    for log in logs:
        for number,line in enumerate(log.read_text(errors='replace').splitlines(),1):
            if BAD.search(line):failures.append(f'{log.name}:{number}: {line}')
    if failures:raise ValueError('Structural/clock build gate rejected image: '+'; '.join(failures[:8]))
    return len(logs)
