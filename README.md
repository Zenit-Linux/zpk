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
* Do liczenia sha256: `sha256sum`, `shasum` (macOS) albo `openssl` --
  `zpk` próbuje po kolei, którekolwiek jest w PATH (patrz "Przenośność").
* Do podpisywania/weryfikacji pakietów: `openssl` >= 3.0 (opcjonalnie --
  wymagane dla Ed25519, patrz "Bezpieczeństwo" niżej).
* Do weryfikacji `depends_on`: `zpm` w PATH (opcjonalnie, patrz `zpk deps`).
* Interpreter wskazany w `recipe.lang` (domyślnie `janet`) -- musi być
  w PATH przy `zpk build`.

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

Dla autentyczności `zpk` opcjonalnie **podpisuje kryptograficznie**
(przez `openssl`, klucz RSA lub Ed25519 w PEM) -- sterowane zmienną
`ZPK_SIGN_KEY` (albo `zpk build --sign-key=<ścieżka>`):

```
ZPK_SIGN_KEY=~/.zpk/signing-key.pem zpk build --release
```

Podpis (base64) ląduje w polu `manifest.signature` -- w środku
archiwum, tak jak reszta manifestu, NIE w osobnym `out/<pakiet>.zpk.sig`
jak wcześniej. Weryfikacja:

```
zpk verify out/hello-world-1.0.0-x86_64.zpk --pubkey=~/.zpk/signing-key.pub
```

**RSA vs Ed25519:** `zpk` wykrywa typ klucza automatycznie i używa
właściwej komendy openssl -- RSA/EC przez `openssl dgst -sign`
(streaming digest), Ed25519 przez `openssl pkeyutl -sign -rawin`
(Ed25519 podpisuje całą wiadomość, nie zewnętrznie liczony skrót;
`dgst -sign` kończy się dla niego błędem "Key type not supported").
Wymaga OpenSSL >= 3.0 dla flagi `-rawin`. Obie ścieżki mają testy
end-to-end z prawdziwymi kluczami generowanymi w czasie testu (patrz
`tests/test_core.nim`, sekcja "signing").

Bez `ZPK_SIGN_KEY`/`--sign-key` zachowanie jest identyczne jak wcześniej
(tylko sha256, bez podpisu) -- podpisywanie jest w pełni opcjonalne i
`zpk` **nigdy** samo nie generuje ani nie przechowuje kluczy.

## Przenośność: liczenie sha256

Zamiast twardej zależności wyłącznie od `sha256sum` (coreutils, nie ma
go domyślnie na macOS), `zpk` próbuje po kolei: `sha256sum` →
`shasum -a 256` → `openssl dgst -sha256` -- używa pierwszego, które
faktycznie znajdzie w PATH. Jeśli żadne nie jest dostępne, `zpk build`
kończy się jasnym błędem zamiast cichego pustego sha256 w manifeście.

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
