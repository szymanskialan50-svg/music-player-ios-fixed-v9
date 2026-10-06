## Zmiany w wersji v6 (animacja tekstu wrócona, przyciski ±10 s na lock screenie)

W ustawieniach: „Lock screen buttons” – ±10 s albo Prev/Next (iOS pokazuje tylko jedną z tych par).

## Zmiany w wersji v5 (odtwarzanie, lock screen, teksty)

- **Pauza → nie da się znowu odtworzyć:** przycisk play/pauza pyta teraz natywną wtyczkę o prawdziwy stan
  (`toggle()`), zamiast zgadywać po fladze w JS. Po powrocie do appki stan jest wysyłany ponownie.
  Dodatkowo odtwarzacz YouTube sam się odbudowuje, gdy strona się nie załaduje albo iOS ubije proces WebView.
- **Lock screen (ikona zamiast odtwarzacza, glitche po pauzie):** WebView YouTube i główny WebView publikowały
  własną „media session" (tytuł + ikona appki) i dublowały komendy z lock screena. Teraz lock screenem dla
  YouTube zarządza wyłącznie wtyczka natywna; sesja audio jest podtrzymywana po pauzie (do 15 min).
- **Piosenka sama się wyłącza:** naprawiony wyścig przy start/stop timera obserwatora, ponawianie startu dla
  stanów `cued`/`unstarted`, pauza przy zmianie trasy audio tylko gdy naprawdę odłączono słuchawki/Bluetooth.
- **Złe fragmenty tekstu:** koniec z „szacowanymi" czasami linii (`ALLOW_ESTIMATED_LYRICS = false` w
  `public/player.html`). Podświetlanie linii działa tylko dla tekstów z prawdziwymi znacznikami czasu, a gdy
  długość wersji z LRCLIB nie pasuje do długości utworu, tekst jest pokazywany jako zwykły.

# Budowanie .apk i .ipa na GitHubie

## 0. Dlaczego appka "wyskakuje po minucie" / wraca stara wersja

To prawie na pewno **nie jest błąd w kodzie appki**, tylko efekt tego, że plik
`.ipa` z tego repo (bez sekretów `IOS_*` opisanych w sekcji 3) jest
**niepodpisany**. iPhone z zasady odmawia uruchamiania niepodpisanego kodu, więc
żeby appka w ogóle wystartowała, musisz ją doinstalować/podpisać narzędziem
typu **Sideloadly** albo **AltStore** swoim własnym Apple ID. Objawy, które
opisujesz, pasują dokładnie do typowych problemów tego procesu:

- **"Po minucie wyskakuje i się ładuje" / appka się zamyka zaraz po otwarciu** —
  najczęściej brak zaufania do certyfikatu: Ustawienia → Ogólne →
  VPN i zarządzanie urządzeniem → (Twój Apple ID) → **Zaufaj**. Jeśli
  używasz darmowego Apple ID, certyfikat/profil wygasa **po 7 dniach** — po
  tym czasie appka też zacznie się zamykać zaraz po starcie, dopóki nie
  zainstalujesz jej (odświeżysz) ponownie przez Sideloadly/AltStore.
- **"Leci stara, usunięta wersja"** — jeśli poprzednia instalacja miała ten sam
  numer wersji/builda, iOS czasem zostaje przy starym binarce z dysku zamiast
  podmienić na nową. W tym workflow dodałem automatyczne zwiększanie numeru
  builda (`CFBundleVersion`) przy każdym uruchomieniu, więc każdy nowy `.ipa`
  jest jednoznacznie "nowszy". Mimo to, przed instalacją nowej wersji zawsze
  **usuń starą appkę z ekranu głównego ręcznie**, zanim zainstalujesz nową.
- Realne, trwałe rozwiązanie (appka nie będzie się psuć co 7 dni) to dodanie
  sekretów `IOS_CERTIFICATE_BASE64` / `IOS_PROVISION_PROFILE_BASE64` z sekcji
  3 — wtedy CI oddaje w pełni podpisany `.ipa` z Twoim własnym certyfikatem
  (płatne konto Apple Developer = profil ważny rok, zamiast 7 dni).

Dodatkowo w tej paczce naprawiłem realny błąd w kodzie natywnym, który psuł
odtwarzanie w tle: funkcja wznawiająca YouTube po zablokowaniu ekranu / zejściu
appki w tło wywoływała JS na **złym** WebView (głównym zamiast tym, w którym
faktycznie żyje odtwarzacz YouTube), więc nic nie robiła — muzyka mogła się
zatrzymywać w tle mimo że kod "próbował" ją wznowić. Zobacz
`capacitor-youtube-player/ios/Plugin/YouTubeCapacitorPlugin.swift`.

## 1. Co zostało naprawione

Wyszukiwarka muzyki (`public/player.html`) wcześniej odpytywała `/api/public/yt-search` —
endpoint, który istniał tylko na serwerze Lovable. W spakowanej aplikacji (iOS/Android)
nie ma żadnego serwera, więc każde wyszukiwanie kończyło się błędem
„Wyszukiwanie nie powiodło się”.

Teraz `player.html` łączy się **bezpośrednio** z oficjalnym YouTube Data API v3
(`googleapis.com`) — dokładnie tak samo jak wcześniej robił to Twój serwer, tylko
że zapytanie leci prosto z aplikacji. Zero backendu, zero Lovable.

**Zanim zbudujesz appkę, musisz to zrobić:**

Otwórz `public/player.html`, znajdź linię (sekcja „SEARCH MUSIC”):

```js
const YOUTUBE_API_KEY = 'YOUR_YOUTUBE_DATA_API_KEY_HERE';
```

i wklej tam swój klucz — **ten sam**, który wcześniej był ustawiony jako
`GOOGLE_API_KEY` w zmiennych środowiskowych na Lovable (Project Settings →
Secrets/Environment variables). Jeśli go nie pamiętasz, wygenerujesz nowy w
[Google Cloud Console](https://console.cloud.google.com/apis/credentials) —
włącz tam „YouTube Data API v3” i utwórz klucz API.

⚠️ Ten klucz trafia do kodu aplikacji, więc technicznie każdy, kto rozpakuje
.apk/.ipa, może go zobaczyć. W Google Cloud Console warto ograniczyć klucz
(„Application restrictions”) do Twojego package name (Android) i bundle ID
(iOS), żeby nikt inny go nie wykorzystał.

Naprawiłem też etykietę zakładki „Szukaj muzyki”, żeby się nie zawijała do
dwóch linii na wąskich ekranach.

**Nowości w tej paczce:**
- Zakładka wyszukiwania nazywa się teraz po prostu **„Search”**.
- Na ekranie odtwarzania okładka kręci się teraz jak prawdziwa **płyta
  winylowa** (rowki, błysk, otwór na środku), a nie po prostu jak okrągłe
  zdjęcie.
- Pod tytułem utworu pojawia się teraz panel z **tekstem piosenki** (białym,
  wyśrodkowanym) — pobierany automatycznie z darmowego, bez klucza API,
  serwisu [lyrics.ovh](https://lyrics.ovh) na podstawie tytułu z YouTube.
  Jeśli serwis nie ma tekstu danego utworu (częste dla remiksów/live), panel
  pokaże „Nie znaleziono tekstu.”

## 2. Co robi workflow (`.github/workflows/build-mobile.yml`)

Dodałem Capacitor (opakowuje `public/player.html` jako natywną appkę) oraz
GitHub Actions, który buduje oba pliki automatycznie po pushu do `main`
(albo ręcznie z zakładki **Actions → Build mobile apps → Run workflow**).

- **Android (.apk)** — działa od razu, zero konfiguracji. Job zawsze tworzy
  **debug APK** (instalowalny po włączeniu „Zainstaluj z nieznanych źródeł”).
  Podpisany **release APK** powstanie dodatkowo, jeśli dodasz sekrety
  (patrz niżej).
- **iOS (.ipa)** — tu jest haczyk, którego nie da się ominąć: Apple wymaga
  podpisania **każdej** aplikacji certyfikatem z Twojego konta Apple
  (Developer Program albo nawet darmowe Apple ID), inaczej iPhone jej nie
  zainstaluje. Bez sekretów opisanych niżej job zbuduje tylko niepodpisane
  archiwum (do weryfikacji, że kod się kompiluje) — nie plik .ipa gotowy do
  instalacji.

## 3. Sekrety do dodania (Settings → Secrets and variables → Actions)

### Android — podpisany release APK (opcjonalnie)
| Sekret | Co to jest |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | Twój plik `.keystore`/`.jks` zakodowany w base64 (`base64 -i klucz.jks`) |
| `ANDROID_KEYSTORE_PASSWORD` | hasło do keystore |
| `ANDROID_KEY_ALIAS` | alias klucza |
| `ANDROID_KEY_PASSWORD` | hasło do klucza |

Nie masz keystore? Wygenerujesz go lokalnie: `keytool -genkey -v -keystore release.keystore -alias upload -keyalg RSA -keysize 2048 -validity 10000`.

### iOS — żeby dostać prawdziwy, instalowalny .ipa (wymagane)
| Sekret | Co to jest |
|---|---|
| `IOS_CERTIFICATE_BASE64` | Twój certyfikat podpisywania (`.p12`) w base64 |
| `IOS_CERTIFICATE_PASSWORD` | hasło do pliku .p12 |
| `IOS_PROVISION_PROFILE_BASE64` | provisioning profile (`.mobileprovision`) w base64 |
| `KEYCHAIN_PASSWORD` | dowolne nowe hasło — używane tylko tymczasowo w CI |

To wymaga posiadania konta Apple Developer (płatne, 99 USD/rok) **albo**
darmowego Apple ID + wygenerowania certyfikatu/profilu lokalnie w Xcode na
Macu (bezpłatne konta pozwalają na side-loading, ale profil trzeba co 7 dni
odnawiać). To jedyna część, której nie da się zautomatyzować bez Twoich
własnych danych od Apple — nie ma w tym obejścia.

## 4. Gdzie znaleźć gotowe pliki

Po zakończeniu workflow: zakładka **Actions** → wybrany bieg → sekcja
**Artifacts** na dole strony → `android-apk` i `ios-build` do pobrania jako
.zip.

## 5. Zmiana ikony aplikacji

Ikonę generuje automatycznie workflow (`@capacitor/assets`) na podstawie
pliku `assets/logo.png` (biały motyw na przezroczystym tle, 1024×1024) i koloru
tła ustawionego na stałe w `.github/workflows/main.yml` (`--iconBackgroundColor`).
Żeby zmienić ikonę: podmień `assets/logo.png` na własny obrazek (kwadrat,
najlepiej z przezroczystym tłem, motyw wyśrodkowany w środkowych ~65%
kadru, żeby nic nie ucięło się przy maskowaniu na okrągłe/zaokrąglone
ikony) i/lub zmień kolor w workflow.

## 6. Budowanie lokalnie (opcjonalnie)

```sh
bun install
npm run prepare:www      # kopiuje public/player.html -> www/index.html
npx cap add android      # albo: npx cap add ios
npx cap sync
npx cap open android     # otwiera Android Studio
npx cap open ios         # otwiera Xcode (tylko na macOS)
```

## Strona do pobierania (folder `strona/`)

1. Wrzuć plik aplikacji do `strona/plik/` jako `MusicPlayer.ipa`.
2. Wgraj repo na GitHuba, w *Settings → Pages* wybierz źródło **GitHub Actions**.
3. Workflow `strona.yml` sam wystawi stronę pod `https://TWOJA-NAZWA.github.io/NAZWA-REPO/`.
