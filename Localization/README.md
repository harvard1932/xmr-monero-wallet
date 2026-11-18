# Interface languages

The wallet includes English plus Arabic, Bengali, Dutch, French, German, Hindi, Indonesian, Italian, Japanese, Korean, Malay, Polish, Portuguese, Russian, Simplified Chinese, Spanish, Swahili, Thai, Traditional Chinese, Turkish and Vietnamese. Choose a language with the globe during onboarding or the picker in Settings. Device language is the default. Arabic supports right-to-left layout.

Translations are partial. The catalog has 92 source strings covering common wallet actions, navigation, balances, fee labels, recovery terms and the backup warning. Bengali, Malay, Swahili and Traditional Chinese include 54 translations each. German includes 92. Other translated languages include 91 each. Advanced controls, some security instructions, the source information page and runtime errors still contain English. Monero seed languages are a separate feature.

Most wallet terminology comes from [Cake Wallet’s MIT-licensed language resources](https://github.com/cake-tech/cake_wallet/tree/0b121b07217ddaa5e3a886e95d2393286728b59d/res/values). Its notice is in `ThirdParty/Cake-translations-LICENSE`. The introductory text and terms in `own.json` and `additional.json` were written for this app. The catalog is compiled into the app. Selecting a language never sends wallet data to a translation service.

Run `python3 Localization/import.py` from the project root to recreate the catalog from its pinned upstream revision and local files. The importer prints each language’s count.
