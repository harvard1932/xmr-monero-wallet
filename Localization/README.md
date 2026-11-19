# Interface languages

The wallet ships English and 22 other languages. The language picker includes Arabic, Bengali, Dutch, French, German, Hindi, Indonesian, Italian, Japanese, Korean, Malay, Polish, Portuguese, Russian, Simplified Chinese, Spanish, Swahili, Swedish, Thai, Traditional Chinese, Turkish and Vietnamese. It initially follows the device language. Choosing Arabic also switches the layout to right-to-left.

The catalogs cover wallet setup and recovery, authentication, payment review, fees, balances and history, contacts, invoices, coin control, cold signing, node and privacy settings, prices, and the Live Activity. The app looks up translations locally. iOS chooses the language for its own permission dialogs. It receives localized camera and Face ID usage descriptions from the app. Addresses, amounts encoded in payment requests, recovery words, user labels and the native engine’s original diagnostic or transaction-review text are preserved.

## Translation sources

The checked-in [interface catalog](../Resources/Localizable.xcstrings) and [permission catalog](../Resources/InfoPlist.xcstrings) are the source of truth. Common wallet terms incorporate the pinned Cake Wallet translations under the MIT license. Other strings include translations written for this project and machine-assisted translations of public interface copy. Machine-assisted entries are marked **Needs Review** in Xcode pending a native speaker’s review. Their text is included in the built app. Translation preparation uses public source copy only. No translation service is part of the wallet runtime. [Upstream revision](https://github.com/cake-tech/cake_wallet/tree/0b121b07217ddaa5e3a886e95d2393286728b59d/res/values) · [License](../ThirdParty/Cake-translations-LICENSE)

## Verification

Run `python3 Localization/check.py` in the project root to validate locale coverage, printf substitutions, unresolved placeholders, known identical terms, and permission descriptions. Run `python3 Localization/check.py --compile` on a Mac with Xcode to compile both catalogs and compare every localized string against the output. After a clean app and widget build, add `--derived-data <build-directory>` to check the compiler-extracted keys.

Keep each format argument’s type and position when translating. For example, `%1$lld` and `%2$lld` can be reordered to match the target language. Protocol identifiers and literal address examples are marked as invariant. Keep native diagnostic details distinct from app-authored guidance.

`python3 Localization/import.py` fills any missing terminology from the pinned upstream revision and the project’s short phrase lists. It preserves existing translations. Ordinary app builds require only the checked-in catalogs.
