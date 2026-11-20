"""正对照通过后检查错误 SPKI 不能被证书回调兜底放行。"""
import json
import os
from pathlib import Path
import subprocess
import sys

repo = Path(__file__).resolve().parents[3]
driver, output = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
output.mkdir(parents=True)
env = dict(os.environ, FLUXDO_NATIVE_PROBE_FORCE_QUIC='1', FLUXDO_PROBE_WRONG_PIN='1')
with (output/'run.log').open('w') as log:
    run = subprocess.run([str(repo/'core/net_core/target/debug/examples/h3_fingerprint_probe.exe'),
                          str(driver), str(output), '--native-probe'],
                         env=env, stdout=log, stderr=subprocess.STDOUT, timeout=240)
capture = json.loads((output/'h3-capture.json').read_text())
results = []
for line in (output/'browser.stdout').read_text().splitlines():
    try:
        value = json.loads(line)
        if isinstance(value, dict) and value.get('negative_pin_control') is True:
            results.append(value)
    except json.JSONDecodeError:
        pass
checks = {'collector_rejected': run.returncode != 0,
          'driver_rejected': capture.get('driver_success') is False,
          'no_application_requests': not capture.get('h3') and not capture.get('tcp_requests'),
          'explicit_negative_result': len(results) == 1 and results[0].get('success') is False and bool(results[0].get('error')),
          'cleanup_complete': len(results) == 1 and results[0].get('main_profile_removed') is True and not results[0].get('cleanup_error')}
summary = {'checks':checks, 'passed':all(checks.values()), 'driver':results}
(output/'negative-control.json').write_text(json.dumps(summary, indent=2)+'\n')
print(json.dumps(summary))
raise SystemExit(0 if summary['passed'] else 1)
