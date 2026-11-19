"""Re-extract MyMonero dictionaries from the pinned upstream headers."""
import argparse
import hashlib
import json
import re
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parent
REVISION = "d0d4ec2c99a1db96518a98ff47773d76cf729d84"
# Match find_seed_language's order in mnemonics/electrum-words.cpp.
HEADERS = {
    "chinese_simplified": "667bb6177b05c52ecc15a871844fc35d427a507890b7ae46da91e323623cf8ba",
    "english": "abe7f377f2443b156ec195dbaedb9fe0effdaae0476d4d1e8c1f583468b822bf",
    "dutch": "13c32c156ed31341e0f76aa2d12e7a8c2021b45cd95ed0e246624f5b009c7a93",
    "french": "553dd82a835032d2ce00980113af2d512c67a56d7d0a73d5607162e1b7f7c802",
    "spanish": "e12a7b8e346b3374fda6df2c6e846edfe51e89d5b8ec62a1ee2d8867029da689",
    "german": "d367763686fac59bd82fb8a252286d4c6178c7f8803e97c644bf290846441fa8",
    "italian": "31a611b1a794e0c46f6da6958fc9fe3e13c81c59579611b244c6de349c883678",
    "portuguese": "e40ee1a9ef4e398c96f01dd55dca741bccf6cc2870776efce7b6cde649eecf88",
    "japanese": "d3469e661457f78e48a781d1a3afd00c8853e252cc414890d92bb6bfce0e602f",
    "russian": "05fbc538960df2488017bdd053f0aad403c830dce5ab6e29535dc73010d78680",
    "esperanto": "9570b666ea9204d600dcda7865ae9b8578c04e991cbe766011a0497a2bc702e7",
    "lojban": "6167fea6ca190ad4dc3564b5bad39865481c3bd54780b86e401d36553c9f4c4a",
    "english_old": "81cff346638bef6641a6095d7e7aa94455fddac972b3a0f518a38fde69714469",
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--local", type=Path, help="Path to an existing upstream mnemonics directory")
args = parser.parse_args()
dictionaries = {}
for name, digest in HEADERS.items():
    if args.local:
        header = (args.local / (name + ".h")).read_bytes()
    else:
        url = f"https://raw.githubusercontent.com/mymonero/monero-core-custom/{REVISION}/mnemonics/{name}.h"
        with urlopen(url, timeout=30) as response:
            header = response.read()
    if hashlib.sha256(header).hexdigest() != digest:
        raise ValueError(f"Upstream checksum mismatch for {name}")
    source = header.decode("utf-8")
    words = re.findall(r'^\s*"([^"]+)",?\s*$', source, flags=re.MULTILINE)
    prefix = re.search(r'Base\("[^"]+", "[^"]+", \{\}, (\d+)\)', source)
    if len(words) != 1626 or not prefix:
        raise ValueError(f"Unexpected dictionary format for {name}")
    if name == "english":
        if words != json.loads((ROOT / "monero-english.json").read_text()):
            raise ValueError("MyMonero English differs from the bundled Monero dictionary")
    else:
        dictionaries[name] = {"prefix": int(prefix.group(1)), "words": words}
output = json.dumps(dictionaries, ensure_ascii=False, indent=2) + "\n"
(ROOT / "mymonero-languages.json").write_text(output, encoding="utf-8")
