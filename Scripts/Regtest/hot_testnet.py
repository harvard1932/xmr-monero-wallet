"""Exercise the unmodified hot wallet on a new, isolated testnet chain."""
import contextlib
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys

from regtest import LocalRPC, free_port, service

COIN = 10 ** 12


def mine(node, count, miner_address):
    # The standard block-template/submit APIs work on testnet. At fixed
    # difficulty one, each unmodified template meets its private PoW target.
    for _ in range(count):
        template = node.call("get_block_template", wallet_address=miner_address, reserve_size=1)
        if int(template["difficulty"]) != 1:
            raise RuntimeError("Refusing a template outside the fixed-difficulty fixture.")
        node.request("submit_block", [template["blocktemplate_blob"]])


def run(work, binaries, app_driver):
    if any(work.iterdir()):
        raise RuntimeError("The private testnet requires an empty temporary directory.")
    node, wallet = LocalRPC(work), LocalRPC(work)
    peer = free_port()
    if len({node.port, wallet.port, peer}) != 3:
        raise RuntimeError("Loopback port collision. Run the test again.")
    wallet_dir = work / "wallets"
    wallet_dir.mkdir(mode=0o700)
    password = secrets.token_hex(32)
    env = dict(os.environ, REGTEST_WALLET_PASSWORD=password, REGTEST_NODE_PASSWORD=node.password, REGTEST_PORT=str(node.port))

    def app(stage):
        subprocess.run([str(app_driver), stage], cwd=work, env=env, check=True)

    def new_wallet(name):
        wallet.call("create_wallet", filename=name, password=password, language="English")
        return wallet.call("get_address")["address"]

    daemon_args = [str(binaries / "monerod"), "--testnet", "--offline", "--fixed-difficulty", "1",
                   "--disable-dns-checkpoints", "--no-igd", "--no-zmq", "--data-dir", str(work / "chain"),
                   "--p2p-bind-ip", "127.0.0.1", "--p2p-bind-port", str(peer), "--rpc-bind-ip", "127.0.0.1",
                   "--rpc-bind-port", str(node.port), "--rpc-login", node.login, "--non-interactive"]
    wallet_args = [str(binaries / "monero-wallet-rpc"), "--testnet", "--wallet-dir", str(wallet_dir),
                   "--shared-ringdb-dir", str(work / "rings"), "--daemon-address", node.url, "--daemon-login", node.login,
                   "--rpc-bind-ip", "127.0.0.1", "--rpc-bind-port", str(wallet.port), "--rpc-login", wallet.login, "--non-interactive"]
    with contextlib.ExitStack() as services:
        daemon = services.enter_context(service(daemon_args, work))
        info = node.wait(daemon, "get_info")
        if (info.get("nettype") != "testnet" or not info.get("offline") or info.get("height") != 1
                or info.get("incoming_connections_count") != 0 or info.get("outgoing_connections_count") != 0):
            raise RuntimeError("Refusing to run outside a fresh offline testnet with zero peers.")
        rpc = services.enter_context(service(wallet_args, work))
        wallet.wait(rpc, "get_version")
        receiver = new_wallet("receiver")
        (work / "destination").write_text(receiver)
        wallet.call("close_wallet")
        app("hot-fixture")
        funding = json.loads((work / "funding-addresses.json").read_text())
        miner = new_wallet("miner")
        mine(node, 81, miner)
        wallet.call("refresh")
        wallet.call("transfer", destinations=[{"amount": 3 * COIN, "address": funding["primary"]},
                                              {"amount": 2 * COIN, "address": funding["subaddress"]}], priority=1)
        mine(node, 12, miner)
        wallet.call("close_wallet")
        app("hot-send")
        txid = (work / "hot-txid").read_text().strip()
        mine(node, 12, miner)
        header = node.call("get_last_block_header")["block_header"]
        if header["major_version"] != 1:
            raise RuntimeError("Unexpected private-testnet protocol version.")
        wallet.call("open_wallet", filename="receiver", password=password)
        wallet.call("refresh")
        received = wallet.call("get_transfer_by_txid", txid=txid)["transfer"]
        if received["amount"] != COIN // 4 or received["confirmations"] < 10 or received["locked"]:
            raise RuntimeError("The independent recipient did not confirm the hot payment.")
        wallet.call("close_wallet")
        wallet.call("open_wallet", filename="hot", password=password)
        wallet.call("refresh")
        sent = wallet.call("get_transfer_by_txid", txid=txid)["transfer"]
        if sent.get("subaddr_indices") != [{"major": 0, "minor": 1}]:
            raise RuntimeError("The payment used an output outside the selected subaddress.")
        wallet.call("close_wallet")
        print("Independent RPC confirmed 0.25 test XMR received and unlocked, spent only from account 0, subaddress 1 (private protocol v1).")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    run(*(Path(value).resolve() for value in sys.argv[1:4]))
