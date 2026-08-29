# zpk

Oficjalny builder pakietów `.zpk` dla [zpm](https://github.com/Zenit-Linux/zpm)
(Zenit Package Manager). Format `.zpk` produkowany przez `zpk` jest
**bit-w-bit kompatybilny** z tym, co `zpm pack` umie zainstalować --
`zpk` to po prostu wyspecjalizowane, samodzielne narzędzie do TEGO
JEDNEGO zadania (budowanie + publikacja pakietu), zamiast robienia
tego ręcznie przez surowe komendy `zpm`.

## Wymagania systemowe

* [Nim](https://nim-lang.org/) >= 2.0 (tylko do budowania `zpk` ze
  źródeł -- gotowa binarka z Releases niczego nie wymaga).
* `git` -- do `zpk schedule-release`/`zpk tutorial-release`.
* [`gh`](https://cli.github.com/) (GitHub CLI), zalogowane (`gh auth
  login`) -- opcjonalnie, do automatycznego tworzenia PR-ów i
  GitHub Releases; bez niego `zpk` podaje instrukcję ręcznego dokończenia.
* Do liczenia sha256: `sha256sum`, `shasum` (macOS) albo `openssl` --
  `zpk` próbuje po kolei, którekolwiek jest w PATH (patrz "Przenośność").
* Do podpisywania/weryfikacji pakietów: `openssl` (opcjonalnie).
* Interpreter wskazany w `recipe.lang` (domyślnie `janet`) -- musi być
  w PATH przy `zpk build` (nie przy `zpk validate`, chyba że bez `-q`).

## Instalacja

`zpk` jest częścią ekosystemu `own` -- wpis w
[`Zenit-Linux/own-repository`](https://github.com/Zenit-Linux/own-repository):

```
zpm own install zpk
```

Albo pobierz binarkę bezpośrednio z
[Releases](https://github.com/Zenit-Linux/zpk/releases) -- dostępne dla
linux-x86_64, macos-x86_64 i macos-aarch64 (patrz "Znane ograniczenia"
niżej odnośnie pozostałych architektur/systemów).

## Szybki start

```
mkdir moj-pakiet && cd moj-pakiet
zpk init                     # tworzy zpk.build + recipe.janet (przykład)
$EDITOR zpk.build             # ustaw name/version/arch/description
$EDITOR recipe.janet           # skrypt budujący -- zostawia pliki w $ZPM_PACKAGE_STAGE_DIR
zpk validate                    # sprawdź zpk.build BEZ budowania (pełna: pliki, interpreter, semver...)
zpk build --verbose              # zbuduj .zpk dla architektury hosta
zpk build --release --verbose     # zbuduj dla WSZYSTKICH architektur z package.arch
zpk clean                          # usuń katalog out/
```

## Struktura pakietu

```
moj-pakiet/
  zpk.build       -- główny plik informacyjny pakietu (HCL) -- patrz niżej
  recipe.janet     -- (albo recipe.<lang> wg recipe.lang) skrypt budujący
  out/               -- wynik `zpk build` -- pliki .zpk + .zpk.json (manifest) + .zpk.sig (jeśli podpisane)
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

release {
  repo       = "https://github.com/Zenit-Linux/own-repository"
  repo_file  = "repo/own-repository.json"
  # branch    = "testing"        # odkomentuj dla publikacji pod branchem
  # release_repo_url = "..."     # domyślnie wykrywane z `git remote origin`
  asset_name = "hello-world"
}
```

`zpk validate` sprawdza to WSZYSTKO: poprawność składni HCL, format
semver `version`, dozwolone znaki w `name`, brak zduplikowanych wpisów
w `arch`, brak zduplikowanych bloków `package{}`/`recipe{}`/`release{}`,
a dodatkowo (ostrzeżenia) -- czy plik recipe istnieje na dysku i czy
interpreter z `recipe.lang` jest w PATH.

### Format HCL -- czego `zpk` (nie) obsługuje

Parser jest CELOWO uproszczonym podzbiorem HCL (bez wyrażeń, referencji
między blokami, funkcji wbudowanych czy heredoc). Obsługuje:

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

Domyślnie recipe to skrypt Janet (`recipe.janet`), ale `recipe.lang`
w `zpk.build` może wskazać dowolny interpreter dostępny w PATH (np.
`sh`, `python3`) -- `zpk` po prostu uruchamia
`<interpreter> <recipe.file>` z ustawionym środowiskiem powyżej.

**Znane ograniczenie -- cross-kompilacja:** `zpk build --release`
buduje dla WSZYSTKICH architektur z `package.arch`, ale robi to
ustawiając wyłącznie `ZPM_PACKAGE_ARCH` w środowisku recipe -- `zpk`
SAMO NIE cross-kompiluje niczego. Jeśli architektura docelowa różni się
od hosta, cała odpowiedzialność za wyprodukowanie poprawnych binarek
(toolchain, `--target`, QEMU, itd.) leży po stronie `recipe.<lang>`.
`zpk` wypisuje ostrzeżenie na stderr, gdy budujesz dla architektury
innej niż host, żeby nie było to niespodzianką dopiero po nieudanej
instalacji na docelowym sprzęcie.

## Bezpieczeństwo: integralność i (opcjonalnie) autentyczność

Każdy zbudowany `.zpk` ma zawsze policzone **sha256** -- zarówno
całego archiwum, jak i każdego pliku w środku (`zpk verify`
sprawdza to pierwsze; `zpm install` przy instalacji odczytuje drugie).
To chroni przed uszkodzeniem/przypadkową zmianą, ale **NIE** dowodzi,
kto zbudował pakiet.

Dla autentyczności `zpk` opcjonalnie **podpisuje kryptograficznie**
(przez `openssl`, klucz RSA lub Ed25519 w PEM) -- sterowane zmienną
`ZPK_SIGN_KEY` (albo `zpk build --sign-key=<ścieżka>`):

```
ZPK_SIGN_KEY=~/.zpk/signing-key.pem zpk build --release
```

Powstaje wtedy `out/<pakiet>.zpk.sig` (podpis, base64) obok manifestu.
Weryfikacja:

```
zpk verify out/hello-world-1.0.0-x86_64.zpk --pubkey=~/.zpk/signing-key.pub
```

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
zpk schedule-release --asset=out/hello-world-1.0.0-x86_64.zpk  # użyj już zbudowanego pliku (jedna architektura)
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

## Znane ograniczenia

* **Cross-kompilacja**: `zpk` nie cross-kompiluje samo (patrz wyżej) --
  odpowiedzialność recipe.
* **Architektury `zpk` samego**: gotowe binarki są publikowane dla
  linux-x86_64, macos-x86_64, macos-aarch64. Linux-aarch64/armv7/riscv64
  wymagałyby cross-toolchainu albo emulacji w CI -- świadomie poza
  obecnym zakresem, budowanie ze źródeł (`nimble buildRelease`)
  działa na każdej platformie, którą wspiera Nim.
* **Parser HCL** to uproszczony podzbiór (patrz sekcja wyżej) -- bez
  wyrażeń, referencji, funkcji czy heredoc.

## Rozwój

```
nimble install -d -y
nimble test          # testy jednostkowe (parser HCL, manifest/walidacja,
                      #  builder, checksum, scalanie own-repository.json)
nim c -d:release --opt:speed -o:bin/zpk src/zpk.nim
```

CI (`.github/workflows/build-bin.yml`) uruchamia testy i pełny
smoke-test (`init` → `validate` → `build` → `verify`) na
ubuntu-latest, macos-13 i macos-latest przy każdym push/PR.
`.github/workflows/build-zpk.yml` publikuje binarki do GitHub Releases
po wypchnięciu tagu `vX.Y[.Z]`.

## Licencja

GPL-3.0 -- patrz [LICENSE](LICENSE).
