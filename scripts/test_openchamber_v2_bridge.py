#!/usr/bin/env python3
"""Exercise the bundled bridge against an isolated, real OpenCode V2 server."""
import base64
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def credential(name):
    claims = {
        "https://api.openai.com/auth": {"chatgpt_account_id": name, "chatgpt_user_id": "user-" + name},
        "https://api.openai.com/profile": {"email": name + "@example.com"},
    }
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return dict(type="oauth", access="fixture." + payload + ".signature", refresh="fixture-" + name,
                expires=4000000000000, accountId=name)


def main():
    binary = os.environ.get("OPENCODE_TEST_BINARY", "/Applications/OpenChamber.app/Contents/Resources/opencode-cli/opencode")
    with tempfile.TemporaryDirectory(prefix="codexplusbar-v2-", dir=os.environ.get("TMPDIR")) as temp:
        root = Path(temp)
        location = root / "bridge"
        plugins = location / ".opencode/plugins"
        plugins.mkdir(parents=True)
        shutil.copy(Path(__file__).resolve().parents[1] / "Resources/codexplusbar-openchamber-v2.mjs", plugins / "codexplusbar.js")
        # Keep the integration test independent of the downloaded model catalog.
        (root / "opencode.json").write_text(json.dumps({"providers": {"openai": {
            "package": "@opencode/ai/providers/openai", "models": {"gpt-5.5": {"name": "Fixture"}},
        }}}))
        data = root / "data/opencode"
        data.mkdir(parents=True)
        original = credential("original")
        legacy = json.dumps({"openai": original, "other-provider": {"type": "api", "key": "keep"}})
        (data / "auth.json").write_text(legacy)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("OPENCODE_", "OPENAI_", "XDG_"))}
        env.update(HOME=str(root), XDG_DATA_HOME=str(root / "data"), XDG_CONFIG_HOME=str(root / "config"),
                   XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"),
                   OPENCODE_SERVER_PASSWORD="fixture-password", OPENCODE_LOG_LEVEL="DEBUG")
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        base = f"http://127.0.0.1:{port}"
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

        def request(path, body=None, directory=location):
            headers = {"Authorization": "Basic " + base64.b64encode(b"opencode:fixture-password").decode(),
                       "Content-Type": "application/json", "x-opencode-directory": str(directory)}
            req = urllib.request.Request(base + path, headers=headers,
                                         data=None if body is None else json.dumps(body).encode())
            with opener.open(req, timeout=60) as response:
                raw = response.read()
                return json.loads(raw) if raw else None

        def rpc(method, payload):
            return request("/api/rpc/codexplusbar.openai/" + method, {"input": payload})["output"]

        with (root / "server.log").open("wb") as log:
            process = subprocess.Popen([binary, "serve", "--hostname", "127.0.0.1", "--port", str(port)],
                                       cwd=root, env=env, stdout=log, stderr=log)
            try:
                for _ in range(120):
                    try:
                        info = request("/api/info")
                        break
                    except (OSError, urllib.error.URLError):
                        if process.poll() is not None:
                            raise RuntimeError("Isolated server exited")
                        time.sleep(0.25)
                else:
                    raise RuntimeError("Isolated server did not start")
                assert info["pid"] == process.pid
                # A fresh V2 DB does not run the legacy upgrade import. Seed
                # synthetic test rows only; production uses OpenCode's APIs.
                with sqlite3.connect(data / "opencode.db") as database:
                    value = dict(type="oauth", methodID="chatgpt-browser", access=original["access"],
                                 refresh=original["refresh"], expires=original["expires"],
                                 metadata={"accountID": original["accountId"]})
                    database.execute("INSERT INTO credential (id,integration_id,label,value,active,time_created,time_updated) VALUES (?,?,?,?,1,1,1)",
                                     ("cred_fixture_original", "openai", "Original", json.dumps(value)))
                    database.execute("INSERT INTO credential (id,integration_id,label,value,active,time_created,time_updated) VALUES (?,?,?,?,1,1,1)",
                                     ("cred_fixture_other", "other-provider", "Other", json.dumps({"type": "key", "key": "keep"})))
                    database.execute("INSERT INTO credential (id,integration_id,label,value,active,time_created,time_updated) VALUES (?,?,?,?,1,2,2)",
                                     ("cred_fixture_placeholder", "openai", "Placeholder", json.dumps(value)))
                request("/api/credential/cred_fixture_original/activate", {})
                before = rpc("read", {})
                assert before["auth"] == original
                # A second loaded location must observe the native switch event.
                request("/api/plugin", directory=root)
                request("/api/integration/openai", directory=root)
                request("/api/provider", directory=root)
                provider = request("/api/provider/openai", directory=root)
                assert provider["data"]["headers"]["chatgpt-account-id"] == "original"
                target = credential("target")
                installed = rpc("import", {"expected": before, "auth": target})
                assert installed["auth"] == target
                assert rpc("read", {}) == installed
                for _ in range(40):
                    provider = request("/api/provider/openai", directory=root)
                    if provider["data"]["headers"].get("chatgpt-account-id") == "target":
                        break
                    time.sleep(0.05)
                else:
                    raise AssertionError("OpenAI provider did not reload after the credential switch")
                assert rpc("read", {"id": before["id"]}) == before
                try:
                    rpc("import", {"expected": before, "auth": credential("stale")})
                    raise AssertionError("Stale switch was accepted")
                except urllib.error.HTTPError:
                    pass
                assert rpc("read", {}) == installed
                request("/api/credential/" + before["id"] + "/activate", {})
                assert rpc("read", {}) == before
                assert (data / "auth.json").read_text() == legacy
                with sqlite3.connect(data.as_uri() + "/opencode.db?mode=ro", uri=True) as database:
                    assert json.loads(database.execute("SELECT value FROM credential WHERE id='cred_fixture_other'").fetchone()[0]) == {"type": "key", "key": "keep"}
                print("PASS: real V2 discovery, credential import, active readback, cross-location provider reload, stale-write rejection, rollback, legacy/other-provider preservation")
                if os.environ.get("OPENCHAMBER_TEST_SWIFT") == "1":
                    # Discovery intentionally rejects two bundled backends;
                    # run the installed-app probes separately from this server.
                    test_env = dict(os.environ, TEST_RUNNER_OPENCHAMBER_V2_TEST_URL=base,
                                    TEST_RUNNER_OPENCHAMBER_RUNTIME_PROBE="0",
                                    TEST_RUNNER_OPENCHAMBER_V2_BRIDGE_PROBE="0")
                    # xcodebuild can hang during test-host shutdown on this Mac;
                    # preserve the complete log for its Swift Testing summary.
                    project = Path(__file__).resolve().parents[1]
                    with (root / "swift-tests.log").open("wb") as test_log:
                        tests = subprocess.Popen(["make", "test", "AGENT_NAME=openchamber-v2"], env=test_env,
                                                 cwd=project, stdout=test_log, stderr=test_log, start_new_session=True)
                        try:
                            result = tests.wait(timeout=120)
                        except subprocess.TimeoutExpired:
                            os.killpg(tests.pid, signal.SIGTERM)
                            tests.wait(timeout=10)
                            result = None
                    output = (root / "swift-tests.log").read_text(errors="replace")
                    native_passed = "Test isolatedServerSwitchesThroughProductionClient() passed" in output
                    summary = [line for line in output.splitlines() if "Test run with" in line]
                    if not native_passed or not summary or "passed" not in summary[-1] or result not in (0, None):
                        print(output[-12000:])
                        raise AssertionError("Swift integration suite did not pass")
                    print(summary[-1])
                    if result is None:
                        print("Swift Testing passed; xcodebuild shutdown timed out (see build/logs/openchamber-v2/test.log).")
            except Exception as error:
                if isinstance(error, urllib.error.HTTPError):
                    print(error.read().decode())
                try:
                    print("Plugins:", [p for p in request("/api/plugin")["data"] if p["source"]["type"] != "builtin"])
                except Exception:
                    pass
                try:
                    print("OpenAI:", request("/api/integration/openai"))
                    print("Config:", request("/api/config", directory=root))
                except Exception:
                    pass
                process.terminate()
                process.wait(timeout=10)
                print("Files:", [str(p.relative_to(root)) for p in root.rglob("*") if p.is_file()][:40])
                print((root / "server.log").read_text(errors="replace")[-6000:])
                for logfile in root.rglob("*.log"):
                    print(logfile.read_text(errors="replace")[-6000:])
                raise
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()
