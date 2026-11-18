"""Rebuild the app's offline string catalog from pinned inputs."""
import concurrent.futures
import json
from pathlib import Path
import urllib.request

HERE = Path(__file__).resolve().parent
CAKE_REVISION = "0b121b07217ddaa5e3a886e95d2393286728b59d"
UPSTREAM = {
    "Address": "address", "Amount": "transaction_details_amount", "Automatic": "automatic",
    "Available": "available", "Back": "seed_alert_back", "Cancel": "cancel", "Close": "close",
    "Coin control": "coin_control_settings", "Confirmations": "confirmations", "Confirmed": "confirmed_tx",
    "Connecting": "sync_connecting", "Contact name": "contact_name", "Contacts": "contacts",
    "Copied": "copied", "Copy": "copy", "Date": "transaction_details_date", "Done": "done",
    "Enter your recovery phrase.": "enter_seed_phrase", "Export outputs": "export_outputs",
    "Fee priority": "settings_fee_priority", "Freeze": "freeze", "Frozen": "frozen", "Label": "label",
    "Loading…": "loading", "Name": "send_name", "Network": "network", "Network fee": "wc_network_fee",
    "Next": "seed_language_next", "Normal": "normal", "OK": "ok", "Offline": "sync_offline",
    "Open wallet": "open_wallet", "Paid": "trade_state_paid", "Pending": "trade_state_pending",
    "Primary address": "primary_address", "Receive": "receive", "Received": "received",
    "Recipient address": "recipient_address", "Recovery phrase": "seed_title",
    "Remove": "remove", "Restore wallet": "wallet_list_restore_wallet", "Save": "save",
    "Save contact": "save_contact", "Scan QR": "wc_scan_qr", "Send": "send_title",
    "Send XMR": "send_xmr", "Sending": "sending", "Sent": "sent", "Settings": "settings_title",
    "Share": "share", "Status": "trade_details_state", "Synchronized": "sync_synced",
    "Synchronizing": "synchronizing", "Total": "total", "Transaction": "transaction",
    "Transaction ID": "transaction_details_transaction_id", "View all": "view_all",
    "Wallet": "wallet", "Wallet name": "wallet_name", "Create a wallet": "wallet_list_create_new_wallet",
    "Restore a wallet": "wallet_list_restore_wallet", "Create wallet": "wallet_list_create_new_wallet",
    "Total balance": "full_balance", "New contact": "add_contact", "View recovery words": "show_recovery_phrase",
    "Private view key": "view_key_private", "Private spend key": "spend_key_private",
    "Primary wallet address": "primary_address", "Seed format": "seedtype", "Unlock wallet": "unlock",
    "Check your backup.": "verify_seed", "Write it down.": "back_up_recovery_phrase",
    "View phrase again": "show_recovery_phrase", "Enter the words in order": "enter_seed_phrase",
    "View-only": "watching", "Locked balance": "unavailable_balance", "Restore height": "wallet_recovery_height",
    "View recovery phrase": "show_recovery_phrase", "Wallets": "wallets", "Invoices": "payment_invoices"
}
OWN = json.loads((HERE / "own.json").read_text())
ADDITIONAL = json.loads((HERE / "additional.json").read_text())
CAKE_LANGUAGES = sorted(set(OWN) - set(ADDITIONAL) - {"en"})

def download(locale):
    source = "zh" if locale == "zh-Hans" else locale
    path = f"res/values/strings_{source}.arb"
    url = f"https://raw.githubusercontent.com/cake-tech/cake_wallet/{CAKE_REVISION}/{path}"
    with urllib.request.urlopen(url, timeout=30) as response:
        strings = json.load(response)
    entries = {}
    for key, identifier in UPSTREAM.items():
        term = strings.get(identifier, "")
        if isinstance(term, str) and term.strip() and all(mark not in term for mark in ("$", "@", "%", "<", ">")):
            entries[key] = term.strip()
    return locale, entries

with concurrent.futures.ThreadPoolExecutor(6) as pool:
    translated = dict(pool.map(download, CAKE_LANGUAGES))
for table in [OWN, ADDITIONAL]:
    for locale, values in table.items():
        assert len(values) == len(table["en"])
        if locale != "en":
            translated.setdefault(locale, {}).update(zip(table["en"], values))
for locale in set(ADDITIONAL) - {"en"}:
    copies = {"Create wallet": "Create a wallet", "Restore wallet": "Restore a wallet",
              "Primary wallet address": "Primary address", "View phrase again": "View recovery words"}
    for label, source in copies.items():
        translated[locale][label] = translated[locale][source]

catalog = {}
for locale, terms in translated.items():
    for source, value in terms.items():
        item = catalog.setdefault(source, {"extractionState": "manual", "localizations": {}})
        item["localizations"][locale] = {"stringUnit": {"state": "translated", "value": value}}
out = {"sourceLanguage": "en", "strings": catalog, "version": "1.0"}
(HERE.parent / "Resources/Localizable.xcstrings").write_text(json.dumps(out, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
print("Source strings:", len(catalog))
for locale in sorted(translated):
    print(locale, len(translated[locale]))
