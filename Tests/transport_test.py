"""Exercise the actual Swift transport against fragmented protocol replies, without credentials."""
import json
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
binary = root / "dist/Codex Usage.app/Contents/MacOS/CodexUsage"
fake_source = '''#!/usr/bin/env python3
import json, os, sys, time
for line in sys.stdin:
    request = json.loads(line)
    with open(os.environ["TEST_METHOD_LOG"], "a") as log:
        log.write(request["method"] + "\\n")
    if request["method"] == "initialize":
        response = {"id": request["id"], "result": {}}
    elif request["method"] == "account/rateLimits/read":
        scenario = os.environ["TEST_SCENARIO"]
        if scenario == "auth":
            response = {"id": request["id"], "error": {"code": -1, "message": "401 Unauthorized"}}
        elif scenario == "malformed":
            response = {"id": request["id"], "result": {"rateLimitsByLimitId": "changed"}}
        elif scenario == "missing":
            response = {"id": request["id"], "result": {"rateLimits": None}}
        else:
            response = {"id": request["id"], "result": {"rateLimitsByLimitId": {"codex": {
                "primary": {"usedPercent": 27, "windowDurationMins": 300},
                "secondary": {"usedPercent": 42, "windowDurationMins": 10080}}}}}
    else:
        continue
    wire = json.dumps(response) + "\\n"
    sys.stdout.write(wire[:9]); sys.stdout.flush(); time.sleep(0.02)
    sys.stdout.write(wire[9:]); sys.stdout.flush()
'''

with tempfile.TemporaryDirectory(prefix="codex-usage-test-") as temporary:
    temp = pathlib.Path(temporary)
    fake = temp / "codex"
    fake.write_text(fake_source)
    fake.chmod(0o700)
    for scenario in ("normal", "auth", "malformed", "missing"):
        log = temp / f"{scenario}.log"
        env = dict(os.environ, CODEX_USAGE_CLI=str(fake), TEST_SCENARIO=scenario, TEST_METHOD_LOG=str(log))
        result = subprocess.run([str(binary), "--probe"], env=env, capture_output=True, text=True, timeout=8)
        methods = log.read_text().splitlines()
        assert methods == ["initialize", "initialized", "account/rateLimits/read"], methods
        if scenario == "normal":
            assert result.returncode == 0, result.stderr
            assert json.loads(result.stdout)["fiveHourUsedPercent"] == 27
            assert json.loads(result.stdout)["weeklyUsedPercent"] == 42
            assert json.loads(result.stdout)["fiveHourRemainingPercent"] == 73
            assert json.loads(result.stdout)["weeklyRemainingPercent"] == 58
        elif scenario == "missing":
            assert result.returncode == 2
            assert json.loads(result.stdout)["fiveHourUsedPercent"] is None
            assert json.loads(result.stdout)["fiveHourRemainingPercent"] is None
        else:
            assert result.returncode == 1
            assert not result.stdout.strip()
print("PASS: 4 transport scenarios; all calls limited to initialization and rate-limit reads")
