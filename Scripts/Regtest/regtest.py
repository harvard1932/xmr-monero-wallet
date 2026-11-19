"""Drive the disposable fakechain. All RPC and generated wallet files stay local."""
import contextlib
import json
import os
from pathlib import Path
import secrets
import signal
import shutil
import socket
import subprocess
import sys
import time

AMOUNT = 1_250_000_000_000


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class LocalRPC:
    def __init__(self, directory):
        self.port = free_port()
        self.password = secrets.token_hex(24)
        self.url = f"http://127.0.0.1:{self.port}"
        self.curl_config = directory / f"rpc-{self.port}.conf"
        self.curl_config.write_text(f'user = "{self.login}"\n')
        self.curl_config.chmod(0o600)

    @property
    def login(self):
        return "regtest:" + self.password

    def call(self, method, **params):
        return self.request(method, params)

    def request(self, method, params):
        payload = json.dumps({"jsonrpc": "2.0", "id": "0", "method": method, "params": params}).encode()
        # epee ties Digest nonces to its HTTP connection. libcurl reuses that
        # connection for the authenticated retry, including the original body.
        args = ["curl", "--config", str(self.curl_config), "--noproxy", "*", "--digest", "--silent",
                "--show-error", "--fail", "--max-time", "90", "--header", "Content-Type: application/json",
                "--data-binary", "@-", self.url + "/json_rpc"]
        result = json.loads(subprocess.run(args, input=payload, capture_output=True, check=True).stdout)
        if "error" in result:
            raise RuntimeError(f"Local {method} failed: {result['error'].get('message')}")
        return result["result"]

    def wait(self, process, method):
        for _ in range(100):
            if process.poll() is not None:
                raise RuntimeError("An isolated test service exited during startup.")
            try:
                return self.call(method)
            except (OSError, RuntimeError, subprocess.CalledProcessError):
                time.sleep(0.2)
        raise RuntimeError("An isolated test service did not start.")


@contextlib.contextmanager
def service(args, directory):
    with open(directory / (Path(args[0]).name + ".log"), "wb") as log:
        process = subprocess.Popen(args, cwd=directory, stdout=log, stderr=subprocess.STDOUT)
        try:
            yield process
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def run(work, binaries):
    node, wallet = LocalRPC(work), LocalRPC(work)
    peer = free_port()
    if len({node.port, wallet.port, peer}) != 3:
        raise RuntimeError("Loopback port collision. Run again.")
    wallet_dir = work / "wallets"
    wallet_dir.mkdir(mode=0o700)
    password = secrets.token_hex(32)
    env = dict(os.environ, REGTEST_PORT=str(node.port), REGTEST_NODE_PASSWORD=node.password, REGTEST_WALLET_PASSWORD=password)
    daemon_args = [str(binaries / "monerod"), "--regtest", "--offline", "--fixed-difficulty", "1", "--no-igd", "--no-zmq",
                   "--data-dir", str(work / "chain"), "--rpc-bind-ip", "127.0.0.1", "--p2p-bind-ip", "127.0.0.1",
                   "--rpc-bind-port", str(node.port), "--p2p-bind-port", str(peer), "--rpc-login", node.login, "--non-interactive"]
    wallet_args = [str(binaries / "monero-wallet-rpc"), "--wallet-dir", str(wallet_dir), "--daemon-address", node.url,
                   "--daemon-login", node.login, "--allow-mismatched-daemon-version", "--rpc-bind-ip", "127.0.0.1",
                   "--rpc-bind-port", str(wallet.port), "--rpc-login", wallet.login, "--non-interactive"]
    with contextlib.ExitStack() as services:
        daemon = services.enter_context(service(daemon_args, work))
        info = node.wait(daemon, "get_info")
        if info.get("nettype") != "fakechain" or info.get("offline") is not True:
            raise RuntimeError("Refusing to operate outside an offline fakechain.")
        rpc = services.enter_context(service(wallet_args, work))
        wallet.wait(rpc, "get_version")
        # All three wallets are created with new keys and have no external connection.
        wallet.call("create_wallet", filename="receiver", password=password, language="English")
        wallet.call("close_wallet")
        def app(command):
            subprocess.run([str(work / "cold-transfer"), command], env=env, cwd=work, check=True)

        app("invoice-address")
        recipient = (work / "destination").read_text()
        wallet.call("create_wallet", filename="sender", password=password, language="English")
        sender = wallet.call("get_address")["address"]
        view_key = wallet.call("query_key", key_type="view_key")["key"]
        wallet.call("close_wallet")
        # Preserve an empty signer with the same keys before any blocks are mined.
        for suffix in ["", ".keys"]:
            shutil.copyfile(wallet_dir / ("sender" + suffix), wallet_dir / ("offline-signer" + suffix))
        node.call("generateblocks", amount_of_blocks=80, wallet_address=sender)
        wallet.call("generate_from_keys", filename="viewer", address=sender, viewkey=view_key, password=password, restore_height=0)
        wallet.call("refresh")
        wallet.call("close_wallet")
        app("pair-outputs")
        wallet.call("open_wallet", filename="viewer", password=password)
        if wallet.call("get_balance")["unlocked_balance"] <= AMOUNT:
            raise RuntimeError("Imported fixture outputs did not unlock.")
        tx = wallet.call("transfer", destinations=[{"amount": AMOUNT, "address": recipient}], priority=1, do_not_relay=True)
        if tx["fee"] <= 0 or not tx.get("unsigned_txset"):
            raise RuntimeError("The fixture transaction lacks a fee or unsigned payload.")
        wallet.call("close_wallet")
        with (work / "unsigned.ur").open("wb") as stream:
            subprocess.run([str(work / "encode-ur")], input=bytes.fromhex(tx["unsigned_txset"]), stdout=stream, check=True)
        app("sign")
        node.call("generateblocks", amount_of_blocks=12, wallet_address=sender)
        wallet.call("open_wallet", filename="receiver", password=password)
        wallet.call("refresh")
        balance = wallet.call("get_balance")
        transfers = wallet.call("get_transfers", **{"in": True}).get("in", [])
        if balance["balance"] != AMOUNT or balance["unlocked_balance"] != AMOUNT or not any(
                tx["amount"] == AMOUNT and tx["confirmations"] >= 10 for tx in transfers):
            raise RuntimeError("The independent recipient failed to confirm the reviewed amount.")
        wallet.call("close_wallet")
        app("receipt")
        print(f"Verified {AMOUNT} atomic units received and unlocked, with a fee of {tx['fee']} atomic units.")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    run(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
