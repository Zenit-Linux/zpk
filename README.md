# zpk

Oficjalny builder pakietów `.zpk` dla [zpm](https://github.com/Zenit-Linux/zpm)
(Zenit Package Manager). Format `.zpk` produkowany przez `zpk` jest
**bit-w-bit kompatybilny** z tym, co `zpm pack` umie zainstalować --
`zpk` to po prostu wyspecjalizowane, samodzielne narzędzie do TEGO
JEDNEGO zadania (budowanie + publikacja pakietu), zamiast robienia
tego ręcznie przez surowe komendy `zpm`. `zpk` samo jest też
dostępne jako pakiet `.zpk` (patrz katalog [`packaging/`](packaging/)).

## Wymagania systemowe

* [Nim](https://nim-lang.org/) >= 2.0 (tylko do budowania `zpk` ze
  źródeł -- gotowa binarka z Releases niczego nie wymaga).
* `git` -- do `zpk schedule-release`/`zpk tutorial-release`.
* [`gh`](https://cli.github.com/) (GitHub CLI), zalogowane (`gh auth
  login`) -- opcjonalnie, do automatycznego tworzenia PR-ów i
  GitHub Releases; bez niego `zpk` podaje instrukcję ręcznego dokończenia.
* Do podpisywania/weryfikacji pakietów: `openssl` >= 3.0 (opcjonalnie --
  wymagane dla Ed25519, patrz "Bezpieczeństwo" niżej). To JEDYNE miejsce,
  w którym `zpk` w ogóle odpala proces potomny do czegoś związanego z
  samym pakietem -- **budowanie, pakowanie i liczenie sum kontrolnych nie
  wymaga już niczego zewnętrznego, patrz "Format `.zpk` -- ZPKA v2" niżej.**
* Do weryfikacji `depends_on`: `zpm` w PATH (opcjonalnie, patrz `zpk deps`).
* Interpreter wskazany w `recipe.lang` (domyślnie `janet`) -- musi być
  w PATH przy `zpk build` (to uruchamia SKRYPT BUDUJĄCY danego pakietu,
  nie samo `zpk` -- odrębna sprawa od pakowania wyniku do `.zpk`).

> **v0.5 -- zero zależności od `tar`/`sha256sum`/`shasum`.** Wcześniej
> `zpk` wymagało `tar` w PATH do pakowania/rozpakowywania i próbowało po
> kolei `sha256sum`/`shasum`/`openssl` do liczenia sum kontrolnych. Od
> v0.5 archiwizacja (nowy format ZPKA) i sha256 są w 100% wkompilowane w
> binarkę `zpk` -- działa identycznie na KAŻDEJ platformie z gotową
> binarką, nawet bez coreutils. Patrz sekcja niżej.

## Instalacja

`zpk` jest częścią ekosystemu `own` -- wpis w
[`Zenit-Linux/own-repository`](https://github.com/Zenit-Linux/own-repository):

```
zpm own install zpk
```

Albo pobierz binarkę bezpośrednio z
[Releases](https://github.com/Zenit-Linux/zpk/releases) -- dostępne dla
linux-x86_64, linux-aarch64, linux-armv7 (pod emulacją QEMU w CI),
macos-x86_64 i macos-aarch64.

> **v0.3.2 -- konwencja nazywania assetów wydań.** `zpm` rozwiązuje
> `{version}` we wpisie `zpk` w `own-repository.json` na dokładny TAG
> release'a z GitHub Releases API (np. `v0.2`) i podstawia go DOSŁOWNIE
> w oczekiwanej nazwie pliku (`zpk-{version}-x86_64.zpk`). Nazwa assetu
> publikowanego przez `.github/workflows/build-zpk.yml` MUSI więc być
> bajt-w-bajt tagiem release'a (`${{ github.ref_name }}`), NIE
> przeliczoną/znormalizowaną wersją (np. bez prefiksu "v") -- rozjazd
> między tymi dwoma powodował ciche 404 przy `zpm own install zpk` i
> `status 'failed'` w bazie zpm (patrz `zpm doctor`). Workflow ma teraz
> krok, który to sprawdza przed publikacją (fail-fast w CI).
> **Uwaga:** obecny `build-zpk.yml` publikuje TYLKO linux-x86_64 -- opis
> "dostępne dla ... aarch64, armv7, macos" wyżej wyprzedza rzeczywisty
> stan CI i wymaga osobnej rozbudowy o macierz `matrix:` (patrz `ci.yml`,
> który TAKĄ macierz już ma dla samych testów, ale nie dla publikacji).

## Szybki start

```
mkdir moj-pakiet && cd moj-pakiet
zpk init                     # tworzy zpk.build + recipe.janet (przykład)
$EDITOR zpk.build             # ustaw name/version/arch/description
$EDITOR recipe.janet           # skrypt budujący -- zostawia pliki w $ZPM_PACKAGE_STAGE_DIR
zpk validate                    # sprawdź zpk.build BEZ budowania (składnia, semver, recipe, depends_on...)
zpk build --verbose              # zbuduj .zpk dla architektury hosta
zpk build --release --verbose     # zbuduj dla WSZYSTKICH architektur z package.arch
zpk deps                           # sprawdź status depends_on (best-effort)
zpk bump-version patch              # podnieś package.version (major/minor/patch)
zpk clean                            # usuń katalog out/
```

## Struktura pakietu

```
moj-pakiet/
  zpk.build       -- główny plik informacyjny pakietu (HCL) -- patrz niżej
  recipe.janet     -- (albo recipe.<lang> wg recipe.lang) skrypt budujący
  out/               -- wynik `zpk build` -- WYŁĄCZNIE pliki .zpk (JEDNO archiwum na
                        architekturę) -- manifest.json (z sumą zawartości i, opcjonalnie,
                        podpisem) leży W ŚRODKU każdego archiwum, nie obok niego jako
                        osobny plik -- patrz "Bezpieczeństwo" niżej
```

### `zpk.build`

```hcl
package {
  name        = "hello-world"
  version     = "1.0.0"
  arch        = ["x86_64", "aarch64"]
  description = "Przykładowy pakiet .zpk"
  depends_on  = []
}

recipe {
  file = "recipe.janet"   # domyślnie
  lang = "janet"          # domyślnie
}

# Opcjonalnie: prefiksy toolchaina cross-kompilacji per architektura --
# patrz sekcja "Cross-kompilacja" niżej.
toolchains {
  aarch64 = "aarch64-linux-gnu-"
}

release {
  repo       = "https://github.com/Zenit-Linux/own-repository"
  repo_file  = "repo/own-repository.json"
  # branch    = "testing"        # odkomentuj dla publikacji pod branchem
  # release_repo_url = "..."     # domyślnie wykrywane z `git remote origin`
  asset_name = "hello-world"
}
```

`zpk validate` sprawdza: poprawność składni HCL, format semver
`version`, dozwolone znaki w `name`, brak zduplikowanych wpisów w
`arch`, brak zduplikowanych bloków `package{}`/`recipe{}`/`release{}`,
czy plik recipe istnieje na dysku, czy interpreter z `recipe.lang` jest
w PATH, oraz (informacyjnie) status `depends_on` -- patrz `zpk deps`.

### Format HCL -- czego `zpk` (nie) obsługuje

Parser jest CELOWO uproszczonym podzbiorem HCL (bez wyrażeń, referencji
między blokami, funkcji wbudowanych czy heredoc), **liniowy** -- każdy
`nazwa {`, `klucz = wartość` i `}` w OSOBNEJ linii. Obsługuje:

* stringi w cudzysłowie z `\"`/`\\` (escape), listy `["a", "b, z przecinkiem", "c"]`
  (przecinek WEWNĄTRZ cudzysłowu nie rozbija elementu),
* liczby całkowite i zmiennoprzecinkowe, w tym ujemne (`-5`, `3.14`),
* `true`/`false`,
* zagnieżdżone bloki `nazwa { ... }` (bez cudzysłowu albo z, np. `recipe {}`),
* komentarze `#` i `//`,
* wykrywa i zgłasza (z numerem linii): niedomknięty string/listę/blok,
  nierozpoznaną wartość, nadmiarowy `}`.

### `recipe.<lang>` (kontrakt)

Recipe dostaje w środowisku:

* `ZPM_PACKAGE_STAGE_DIR` -- katalog, w którym **musisz** zostawić
  gotowe pliki do zainstalowania, ścieżki **względem `/`**
  (np. `usr/local/bin/hello-world`).
* `ZPM_PACKAGE_NAME`, `ZPM_PACKAGE_VERSION`, `ZPM_PACKAGE_ARCH`.
* `ZPM_QEMU_STATIC` -- ścieżka do `qemu-<arch>-static`, jeśli `zpk`
  znalazło je w PATH przy budowaniu cross-arch (patrz niżej).
* `CC`/`CXX`/`AR`/`STRIP`/`ZPM_PACKAGE_CROSS_PREFIX` -- jeśli
  `zpk.build` ma blok `toolchains { <arch> = "prefiks-" }` dla budowanej
  architektury (patrz niżej).

Domyślnie recipe to skrypt Janet (`recipe.janet`), ale `recipe.lang`
w `zpk.build` może wskazać dowolny interpreter dostępny w PATH (np.
`sh`, `python3`) -- `zpk` po prostu uruchamia
`<interpreter> <recipe.file>` z ustawionym środowiskiem powyżej.

### Cross-kompilacja

`zpk` samo NIE cross-kompiluje kodu -- ale daje recipe dwie konkretne,
choć celowo wąskie, pomoce:

1. **`toolchains { <arch> = "prefiks-" }`** w `zpk.build` -- `zpk`
   ustawia `CC`/`CXX`/`AR`/`STRIP` na `<prefiks>gcc` itd. dla budowanej
   architektury. Standardowe zmienne, które `make`/`configure`/`cgo`
   (Go przez CGO) faktycznie odczytują -- ale to NIE gwarancja: recipe
   wywołujące kompilator ręcznie (bez configure/make) wciąż musi samo
   je uwzględnić.
2. **`ZPM_QEMU_STATIC`** -- jeśli `qemu-<arch>-static` jest w PATH
   (typowe po `docker/setup-qemu-action` albo `apt install
   qemu-user-static`), `zpk` przekazuje jego ścieżkę do recipe --
   przydatne np. do uruchamiania cross-skompilowanych testów.

Cała reszta (sysroot, `--target`, konfiguracja binfmt_misc, języki z
własnym mechanizmem cross-target jak Rust/`cargo` czy Zig) leży po
stronie `recipe.<lang>`. Jeśli architektura docelowa różni się od
hosta, `zpk` wypisuje na stderr informację o tym, co skonfigurowało
(toolchain/qemu) i czego NIE -- żeby nie było to niespodzianką dopiero
po nieudanej instalacji na docelowym sprzęcie.

### `depends_on` -- weryfikacja (best-effort)

```
zpk deps                # pełny raport: zainstalowana / BRAK / nie można sprawdzić
```

`package.depends_on` było wcześniej czysto deklaratywne (zapisywane do
manifestu, nigdy nie sprawdzane). `zpk deps` (i `zpk validate`)
odpytuje `zpm list --installed`, jeśli `zpm` jest w PATH; bez `zpm`,
sprawdza czy istnieje binarka o tej samej nazwie w PATH (słabsze
przybliżenie, ale lepsze niż nic). To HEURYSTYKA, nie twarda gwarancja
integracji z `zpm` -- status "nie można sprawdzić" (zamiast fałszywego
"BRAK") pojawia się, gdy `zpm` zwróci błąd.

### `zpk bump-version` -- podnoszenie wersji

```
zpk bump-version              # domyślnie: patch (1.2.3 -> 1.2.4)
zpk bump-version minor        # 1.2.3 -> 1.3.0
zpk bump-version major        # 1.2.3 -> 2.0.0
zpk bump-version --set=2.0.0  # ustaw jawnie
```

Podmienia WYŁĄCZNIE wartość `version` w `zpk.build`, zachowując
komentarze i formatowanie reszty pliku bez zmian.

## Format `.zpk` -- ZPKA v2 (natywny, zero zależności zewnętrznych)

Od v0.5 `zpk build` NIE odpala już `tar` (ani żadnego innego procesu
potomnego) do zapakowania pakietu -- cały mechanizm archiwizacji jest
własnym, w 100% czysto-Nimowym formatem kontenera, wkompilowanym w
binarkę `zpk`/`zpm` (`src/zpkpkg/archive.nim` + `zlz.nim` + `zsha256.nim`,
identyczny kod po obu stronach -- patrz też `zpm`). Zero linkowania z
`libz`/`liblzma`/`libzstd`, zero odpalania `gzip`/`xz`/`zstd`/`sha256sum`.

### Dlaczego to realna, a nie kosmetyczna zmiana

Poprzedni kod budował archiwum przez `tar --numeric-owner ... -acf
plik.zpk .`. Flaga `-a` (auto-compress) GNU tar rozpoznaje, czy
kompresować, WYŁĄCZNIE po rozszerzeniu pliku wyjściowego (`.gz`, `.xz`,
`.zst`...) -- `.zpk` nie jest na tej liście, więc **kompresja nigdy się
nie włączała**. Każdy dotychczasowy `.zpk` był w praktyce surowym,
NIESKOMPRESOWANYM archiwum tar (plus narzut 512-bajtowych bloków
nagłówkowych na każdy plik i wyrównania do granicy bloku) -- zmieniony
tylko z rozszerzenia. Nowy format ZPKA:

* **Kompresuje każdy plik niezależnie** (`ZLZ1` -- własny, prosty LZ77 z
  tabelą hashy i tokenami o zmiennej długości, patrz komentarz w
  `zlz.nim`) -- jeśli kompresja by powiększyła dany plik (np. już
  skompresowane obrazki/binarki), zapisywany jest surowo, więc archiwum
  NIGDY nie jest gorsze niż suma rozmiarów plików, tylko lepiej. Na
  typowych zestawach (kod źródłowy, configi, binarki ELF) daje realną,
  wyraźną redukcję rozmiaru -- bez najmniejszego narzutu boilerplate'u,
  jaki miał tar (nagłówki 512 B/plik, wyrównanie bloków).
* **Nie ma bloków wyrównania ani nagłówków tar** -- zwarty binarny spis
  treści (TOC) zamiast tekstowych nagłówków `ustar` na każdy plik.
* **Daje dostęp O(1) do pojedynczego pliku** (np. `manifest.json`) --
  TOC leży w stopce archiwum (jak EOCD w ZIP), więc odczyt jednego pliku
  NIE wymaga skanowania/rozpakowania reszty, w przeciwieństwie do `tar
  -xOf`, które i tak przechodzi przez strumień archiwum.
* **Selektywna, allowlistowa instalacja bez podprocesu** -- `zpm`
  rozpakowuje WYŁĄCZNIE pliki wymienione w `manifest.files` bezpośrednio
  z TOC (`archive.extractSelected`), bez `tar -xf ... -- p1 p2 ...`.
* **Każdy wpis TOC niesie własne sha256** (liczone przy budowaniu),
  sprawdzane automatycznie przy KAŻDEJ dekompresji -- uszkodzenie
  pojedynczego pliku jest wykrywane natychmiast, nie dopiero po pełnym
  rozpakowaniu całości.

### Format na dysku (skrót, pełny opis w `src/zpkpkg/archive.nim`)

```
"ZPKA" + wersja(1B) + flagi(1B)              <- nagłówek (6 B)
<blok danych pliku 1> <blok danych pliku 2> ...  <- ładunek, skompresowany per-plik
<TOC: ścieżka, flagi, offset, rozmiary, sha256[32]>  <- posortowane wg ścieżki
"ZEND" + liczbaWpisów(4B) + offsetTOC(8B)    <- stopka (16 B, czytana od końca pliku)
```

`zpk verify`/`zpm verify`/`zpm install` odczytują NAJPIERW stopkę (ostatnie
16 bajtów pliku), potem TOC -- rozpoznanie formatu i lista plików nie
wymaga wczytania ładunku. Wykrywanie: `isZpkaFile` sprawdza magic `ZPKA`
na początku pliku.

### v0.6 -- lepsza kompresja (ZLZ2) i strumieniowanie dużych plików

Oprócz ZLZ1 (LZ77 bez etapu entropijnego, opisany wyżej) `archive.nim`
umie też **ZLZ2** -- LZ77 + kanoniczne kodowanie Huffmana (jak DEFLATE),
blokami po 1 MiB (`zlz2.nim`, też czysty Nim). Dla każdego pliku
<= 4 MiB `zpk build` próbuje surowo/ZLZ1/ZLZ2 i wybiera najmniejszy
wynik -- ZLZ2 zwykle daje dodatkowe 10-30% redukcji względem ZLZ1 na
danych tekstowych/binarnych (patrz `tests/test_v06_features.nim`).

Dla plików WIĘKSZYCH niż 4 MiB `zpk build` przechodzi na tryb
**strumieniowy**: czyta i kompresuje plik blokami bezpośrednio z dysku,
bez wczytywania całości do pamięci naraz -- ważne przy pakietach z
wielogigabajtowymi binarkami/danymi, gdzie poprzednie podejście
(`readFile` całego pliku) mogłoby wyczerpać pamięć. Rozpakowywanie
takich wpisów (`zpm install`) jest tak samo strumieniowe -- pisze każdy
zdekompresowany blok wprost do pliku docelowego, z bieżąco liczoną sumą
sha256, zamiast budować całą zawartość w pamięci przed zapisem.

### Zgodność wsteczna -- pakiety trzeba przebudować

To ZMIANA ŁAMIĄCA format binarny: pakiety `.zpk` zbudowane przez `zpk <
0.5` (surowy tar) NIE są czytelne przez `zpk >= 0.5`/`zpm >= 0.5` --
`zpk verify`/`zpm install` zwrócą jasny komunikat "to prawdopodobnie
starszy pakiet .zpk budowany tar-em... przebuduj go bieżącym `zpk
build`", zamiast mylącego błędu parsowania. Repozytoria (`own-repository`
i natywny indeks `zpm`) wymagają przebudowania i ponownej publikacji
wszystkich pakietów `.zpk` po aktualizacji do v0.5 -- jednorazowy koszt
w zamian za pełną niezależność od narzędzi zewnętrznych i mniejsze pliki.

## Bezpieczeństwo: integralność i (opcjonalnie) autentyczność

**Manifest (`manifest.json`) leży W ŚRODKU każdego archiwum `.zpk`, NIE
w osobnym pliku obok niego** -- wcześniej `zpk build` produkowało
`out/<pakiet>.zpk` + `out/<pakiet>.zpk.json` (manifest) + opcjonalnie
`out/<pakiet>.zpk.sig` (podpis) jako TRZY osobne pliki; łatwo było
skopiować/opublikować samo `.zpk`, zgubić po drodze manifest/podpis, i
dystrybuować pakiet bez żadnego z nich. Teraz `zpk build` produkuje
WYŁĄCZNIE `<pakiet>.zpk` -- manifest (z sumą kontrolną i, opcjonalnie,
podpisem) jest częścią tego samego archiwum, więc nie da się go zgubić
ani rozdzielić od pakietu, do którego należy.

Każdy zbudowany `.zpk` ma zawsze policzone **sha256** każdego pliku
ładunku w środku ORAZ jedną zagregowaną sumę całej zawartości
(`manifest.sha256` -- sha256 posortowanej listy `ścieżka+sha256`
wszystkich plików; NIE jest to suma bajtów samego archiwum .zpk, bo
plik nie może w prosty sposób nieść sumy samego siebie). `zpk verify`
wyciąga manifest z ARCHIWUM (nie z sąsiedniego pliku), rozpakowuje
zawartość do katalogu tymczasowego i przelicza obie sumy od nowa. To
chroni przed uszkodzeniem/przypadkową zmianą, ale **NIE** dowodzi, kto
zbudował pakiet.

Dla autentyczności `zpk` opcjonalnie **podpisuje kryptograficznie** --
sterowane zmienną `ZPK_SIGN_KEY` (albo `zpk build --sign-key=<ścieżka>`).
Od v0.6 są DWIE drogi:

**1. Natywny Ed25519 (zalecane, zero zależności od `openssl`):**

```
zpk genkey ~/.zpk/signing-key          # tworzy signing-key.priv/.pub, czysty Nim
ZPK_SIGN_KEY=~/.zpk/signing-key.priv zpk build --release
zpk verify out/hello-world-1.0.0-x86_64.zpk --pubkey=~/.zpk/signing-key.pub
```

`zpk genkey` generuje parę kluczy Ed25519 w 100% w Nim (`ed25519.nim` --
własna implementacja RFC 8032: SHA-512 + arytmetyka mod 2^255-19 +
skręcona krzywa Edwardsa, bez linkowania z `libcrypto`/`libsodium`),
ziarno z `std/sysrand` (bezpieczny generator systemowy: `getrandom` na
Linuksie, `arc4random` na macOS/BSD, `CryptGenRandom` na Windows -- NIE
`std/random`). Klucze zapisywane jako czytelny tekst z nagłówkiem
`-----BEGIN ZPK NATIVE ED25519 ...-----` (jawnie odróżnialny od PEM).
Zweryfikowane end-to-end wobec niezależnej biblioteki `cryptography`/
OpenSSL (wygenerowane podpisy bit-w-bit identyczne z referencją na 15
wektorach, w tym wiadomości do 5000 bajtów -- patrz
`tests/test_v06_features.nim`).

> **Uwaga o dojrzałości:** to własna implementacja prymitywu
> kryptograficznego, poprawna funkcjonalnie (patrz testy), ale bez
> profesjonalnego audytu bezpieczeństwa i BEZ odporności na ataki przez
> kanał boczny (czas wykonania zależy od klucza). Dla modelu zagrożeń
> `zpk`/`zpm` (podpis integralności weryfikowany lokalnie, klucz nigdy
> nie opuszcza maszyny budującej) ryzyko jest niskie, ale to nie jest
> zamiennik dla zastosowań o wysokiej stawce bezpieczeństwa -- tam nadal
> lepszy jest sprawdzony `openssl`/`libsodium` (droga 2. niżej).

**2. PEM przez `openssl` (RSA/EC/Ed25519, zgodność wsteczna):**

```
ZPK_SIGN_KEY=~/.zpk/signing-key.pem zpk build --release
```

`zpk` wykrywa typ klucza automatycznie -- RSA/EC przez `openssl dgst
-sign` (streaming digest), Ed25519-PEM przez `openssl pkeyutl -sign
-rawin` (wymaga OpenSSL >= 3.0). Zachowane dla kogoś, kto już ma
klucz/łańcuch zaufania z tej strony (np. firmowy HSM/CA).

Podpis (base64) ląduje w polu `manifest.signature` -- w środku
archiwum, niezależnie od tego, którą z dwóch dróg powstał; `zpk
verify`/`zpm verify` rozpoznają format klucza automatycznie po
pierwszej linii pliku i nie wymagają, żeby użytkownik wiedział, której
drogi użyto.

Bez `ZPK_SIGN_KEY`/`--sign-key` zachowanie jest identyczne jak wcześniej
(tylko sha256, bez podpisu) -- podpisywanie jest w pełni opcjonalne i
`zpk` **nigdy** samo nie generuje ani nie przechowuje kluczy poza
wyraźnym `zpk genkey`.

## Reprodukowalne buildy (`SOURCE_DATE_EPOCH`)

Archiwum ZPKA samo w sobie NIE niesie żadnych metadanych systemowych
(mtime/uid/gid/uprawnienia) -- w przeciwieństwie do `tar`, więc ten
źródłowy szum nie istnieje od początku. Jedynym źródłem niedeterminizmu
był znacznik czasu budowania (`manifest.built_at`, domyślnie "teraz").
Ustawienie `SOURCE_DATE_EPOCH` (konwencja z reproducible-builds.org,
używana też przez Debiana) na stały unix-timestamp sprawia, że DWA
buildy tej samej zawartości (to samo `zpk.build`+recipe, ten sam
`SOURCE_DATE_EPOCH`, ten sam klucz podpisujący) dają **bajt-w-bajt
identyczny** plik `.zpk` -- w tym identyczny podpis (Ed25519/EdDSA jest
deterministyczne z definicji: ten sam klucz+wiadomość zawsze dają ten
sam podpis, bez losowego nonce jak w RSA-PSS/ECDSA):

```
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) zpk build --release
```

`manifest.files` jest też jawnie sortowane po ścieżce (niezależnie od
kolejności zwracanej przez system plików, która nie jest gwarantowana)
-- patrz `tests/test_v06_features.nim` dla testu porównującego dwa
niezależne buildy tego samego pakietu bajt po bajcie.

## `zpk inspect` -- podgląd zawartości pakietu bez instalacji

```
zpk inspect out/hello-world-1.0.0-x86_64.zpk
```

Wypisuje każdy plik w archiwum z rozmiarem surowym/skompresowanym,
metodą kompresji (surowo/ZLZ1/ZLZ2) i współczynnikiem, plus podsumowanie
całego pakietu. Czyta WYŁĄCZNIE spis treści (TOC) w stopce archiwum --
nie rozpakowuje ani nie dotyka ładunku, więc działa błyskawicznie
niezależnie od rozmiaru pakietu.

## `zpk diff` -- różnice między dwiema wersjami pakietu

```
zpk diff old/hello-world-1.0.0-x86_64.zpk out/hello-world-1.1.0-x86_64.zpk
```

Porównuje TOC obu archiwów (ścieżka + sha256 + rozmiar) i wypisuje
dodane/usunięte/zmienione pliki -- też bez rozpakowania jednego bajtu
ładunku którejkolwiek strony. Przydatne w CI do szybkiego przeglądu "co
się zmieniło w tym release'ie" bez ręcznego rozpakowywania dwóch
archiwów.

## `zpk delta` -- małe aktualizacje zamiast pełnego pobierania

```
zpk delta old/hello-world-1.0.0-x86_64.zpk out/hello-world-1.1.0-x86_64.zpk update.zpkd
```

Buduje plik delty (`.zpkd`) zawierający TYLKO payload plików, których
zawartość (sha256) różni się od starej wersji -- pliki niezmienione są w
delcie jedynie ODNIESIENIEM ("weź to z old.zpk"), dopasowanym po TREŚCI,
nie po ścieżce (przeniesiony/przemianowany, ale identyczny plik nadal
korzysta z reużycia). W typowej aktualizacji patch-level delta bywa
rzędu kilku-kilkunastu procent rozmiaru pełnego archiwum (patrz test w
`tests/test_v06_features.nim`, gdzie delta to ~8% pełnego pakietu przy
zmianie 3 z 5 plików). Po stronie instalującej: `zpm apply-delta
old.zpk update.zpkd new.zpk` odtwarza pełne archiwum -- bajt-w-bajt
identyczne z tym, co dałoby pobranie `new.zpk` w całości -- kopiując
niezmienione bloki wprost ze starego archiwum, bez ponownej kompresji.

## `zpk migrate` -- przepakowanie starych pakietów (opt-in, jedyne użycie `tar`)

```
zpk migrate legacy-package.zpk legacy-package-migrated.zpk
```

Pakiety `.zpk` zbudowane przez `zpk < 0.5` (surowy tar, patrz sekcja
"Format .zpk" niżej) NIE są czytelne przez `zpk >= 0.5`/`zpm >= 0.5`.
Zamiast wymagać przebudowania od zera z oryginalnego recipe (które może
już nie być pod ręką), `zpk migrate` rozpakowuje stary tarball i pakuje
go od nowa do formatu ZPKA v2 -- manifest (w tym sha256/podpis, jeśli
pakiet był podpisany) jest przenoszony BEZ ZMIAN, bo dotyczy treści
plików, nie kontenera. To JEDYNE miejsce w całym `zpk`/`zpm`, które
nadal (świadomie, tylko na wyraźne żądanie) korzysta z systemowego
`tar` -- bo to jedyny sposób odczytania formatu, którego `archive.nim`
celowo nie obsługuje. Jeśli `tar` nie jest dostępny w PATH, komenda
kończy się jasnym błędem zamiast ukrytego fallbacku.

## Przenośność: liczenie sha256

Od v0.5 sha256 liczy WŁASNA implementacja w czystym Nim (`zsha256.nim`,
FIPS 180-4, testowana wektorami NIST) -- zero zależności od `sha256sum`/
`shasum`/`openssl` do tego celu. Identyczny wynik na każdej platformie,
bez procesu potomnego per plik (szybciej niż poprzednie fork+exec).
(Wcześniej `zpk` próbowało po kolei `sha256sum` → `shasum -a 256` →
`openssl dgst -sha256`, cokolwiek znalazło w PATH -- ten kod został
usunięty razem z resztą zależności od narzędzi zewnętrznych do budowania
archiwum.)

## Publikacja: `zpk schedule-release`

Tworzy Pull Request do
[`Zenit-Linux/own-repository`](https://github.com/Zenit-Linux/own-repository)
z nowym/zaktualizowanym wpisem tego pakietu -- domyślnie buduje
WSZYSTKIE architektury z `package.arch` (nie tylko pierwszą) i publikuje
wpis odpowiedni dla liczby zbudowanych architektur: `"bin"` jako zwykły
URL (string), jeśli jest tylko jedna, albo obiekt `{"x86_64": url,
"aarch64": url, ...}`, jeśli jest więcej:

```
zpk schedule-release                        # buduje WSZYSTKIE arch + PR z domyślnym (top-level) wariantem
zpk schedule-release --branch=testing        # PR aktualizujący TYLKO branch "testing"
zpk schedule-release --asset=out/x-1.0.0-x86_64.zpk --asset=out/x-1.0.0-aarch64.zpk  # gotowe pliki, MOŻNA wielokrotnie
zpk schedule-release --dry-run               # przygotuj i pokaż zmiany BEZ push/PR/upload
zpk schedule-release --skip-upload           # tylko PR do own-repository.json, bez tworzenia GitHub Release
```

Wymaga [`gh`](https://cli.github.com/) (GitHub CLI), już zalogowanego
(`gh auth login`) -- `zpk` samo nigdy nie dotyka Twoich poświadczeń,
deleguje autentykację w całości do `gh`. Bez `gh` w PATH, `zpk`
zatrzymuje się po lokalnym commicie i podaje dokładną instrukcję,
co zrobić ręcznie (`git push` + `gh pr create` / PR ręcznie na GitHubie).

**Kto faktycznie wgrywa plik `.zpk` na GitHub Releases?** Jeśli `gh`
jest dostępne, **`zpk` samo** tworzy (albo aktualizuje, jeśli już
istnieje) GitHub Release o tagu `vX.Y.Z` w repo źródłowym pakietu
(wykrywanym z `git remote get-url origin`, albo `release.release_repo_url`
w `zpk.build`) i wgrywa tam zbudowany plik jako asset -- URL wpisywany
do `own-repository.json` więc od razu wskazuje na coś, co istnieje.
Bez `gh` (albo z `--skip-upload`), `zpk` wypisuje dokładną komendę do
ręcznego wykonania -- **nic nie publikuje w ciemno**.

**Odporność na race condition i weryfikacja uploadu:** zamiast
sprawdzać najpierw `gh release view` a potem `create`/`upload`
(zostawiając okno czasowe, w którym równoległy bieg CI mógł stworzyć
release jako pierwszy), `zpk` od razu próbuje `create`; jeśli się nie
uda (release już istnieje -- niezależnie czy przez nas wcześniej, czy
przez kogoś innego w międzyczasie), automatycznie próbuje `upload
--clobber`. Po udanym `create`/`upload`, `zpk` DODATKOWO odpytuje `gh
release view --json assets` i sprawdza, czy plik faktycznie figuruje
na liście -- kod wyjścia 0 z `gh` nie zawsze oznacza, że upload się
naprawdę powiódł (bywa niekonsekwentne przy przerwanym połączeniu).

### `zpk tutorial-release` -- interaktywny kreator

Dla osób, które wolą przejść przez proces pytanie-po-pytaniu zamiast
pamiętać wszystkie flagi:

```
zpk tutorial-release
ZPK_LANG=pl zpk tutorial-release   # po polsku
```

Jeśli wybierzesz "nie buduj teraz", kreator sam sprawdza, czy pliki
`.zpk` dla WSZYSTKICH architektur z `package.arch` faktycznie już
istnieją w `out/` -- architektury, dla których pliku brakuje, są
pomijane przy publikacji (z ostrzeżeniem), zamiast wpisać URL
wskazujący donikąd.

## `zpk verify` -- sprawdzanie gotowego pakietu

```
zpk verify out/hello-world-1.0.0-x86_64.zpk                       # tylko integralność (sha256)
zpk verify out/hello-world-1.0.0-x86_64.zpk --pubkey=klucz.pub     # + autentyczność (podpis)
```

## Dlaczego `.zpk`, nie `curl | sh`

`.zpk` to format binarny z manifestem (nazwa, wersja, architektura,
zależności, suma sha256 archiwum I każdego pliku w środku, opcjonalnie
podpis kryptograficzny -- patrz "Bezpieczeństwo" wyżej) -- `zpm install
pakiet.zpk` weryfikuje integralność przed rozpakowaniem, w
przeciwieństwie do pobrania i uruchomienia dowolnego skryptu
instalacyjnego z internetu.

## `zpk` jako pakiet `.zpk` (self-hosting)

Katalog [`packaging/`](packaging/) zawiera `zpk.build`/`recipe.janet`
pozwalające zapakować SAMO `zpk` jako `.zpk`, instalowalny przez
`zpm install` -- patrz [`packaging/README.md`](packaging/README.md).

## Znane ograniczenia

* **Cross-kompilacja**: `zpk` nie cross-kompiluje kodu samo -- daje
  recipe `toolchains`/`ZPM_QEMU_STATIC` (patrz wyżej), ale sysroot,
  `--target` i języki z własnym mechanizmem cross-target zostają po
  stronie recipe.
* **Parser HCL** to uproszczony, liniowy podzbiór (patrz sekcja wyżej)
  -- bez wyrażeń, referencji, funkcji czy heredoc; każda dyrektywa w
  osobnej linii.
* **Weryfikacja `depends_on`** to heurystyka (patrz sekcja wyżej), nie
  twarda integracja z rozwiązywaniem zależności `zpm`.
* **`zpk.build` w `packaging/`** wymaga ręcznej synchronizacji wersji z
  `zpk.nimble`/`src/zpk.nim` -- HCL nie ma odwołań między plikami.

## Rozwój

```
nimble install -d -y
nimble test          # testy jednostkowe: parser HCL, manifest/walidacja,
                      # builder, checksum, podpisywanie (RSA+Ed25519, prawdziwe
                      # klucze openssl), deps, bump-version, scalanie
                      # own-repository.json, integracja schedule-release
                      # (prawdziwy git + zamockowany/nieobecny gh),
                      # tutorial-release (end-to-end)
nim c -d:release --opt:speed -o:bin/zpk src/zpk.nim
```

CI (`.github/workflows/build-bin.yml`) uruchamia testy i pełny
smoke-test (`init` → `validate` → `build` → `verify`) na
ubuntu-latest, macos-13, macos-latest ORAZ linux-aarch64/armv7 pod
emulacją QEMU przy każdym push/PR. `.github/workflows/build-zpk.yml`
publikuje binarki dla wszystkich pięciu platform do GitHub Releases po
wypchnięciu tagu `vX.Y[.Z]`.

## Licencja

GPL-3.0 -- patrz [LICENSE](LICENSE).
