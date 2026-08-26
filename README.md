# zpk

Oficjalny builder pakietów `.zpk` dla [zpm](https://github.com/Zenit-Linux/zpm)
(Zenit Package Manager). Format `.zpk` produkowany przez `zpk` jest
**bit-w-bit kompatybilny** z tym, co `zpm pack` umie zainstalować --
`zpk` to po prostu wyspecjalizowane, samodzielne narzędzie do TEGO
JEDNEGO zadania (budowanie + publikacja pakietu), zamiast robienia
tego ręcznie przez surowe komendy `zpm`.

## Instalacja

`zpk` jest częścią ekosystemu `own` -- wpis w
[`Zenit-Linux/own-repository`](https://github.com/Zenit-Linux/own-repository):

```
zpm own install zpk
```

Albo pobierz binarkę bezpośrednio z
[Releases](https://github.com/Zenit-Linux/zpk/releases).

## Szybki start

```
mkdir moj-pakiet && cd moj-pakiet
zpk init                     # tworzy zpk.build + recipe.janet (przykład)
$EDITOR zpk.build             # ustaw name/version/arch/description
$EDITOR recipe.janet           # skrypt budujący -- zostawia pliki w $ZPM_PACKAGE_STAGE_DIR
zpk validate                    # sprawdź zpk.build bez budowania
zpk build --verbose              # zbuduj .zpk dla architektury hosta
zpk build --release --verbose     # zbuduj dla WSZYSTKICH architektur z package.arch
```

## Struktura pakietu

```
moj-pakiet/
  zpk.build       -- główny plik informacyjny pakietu (HCL) -- patrz niżej
  recipe.janet     -- (albo recipe.<lang> wg recipe.lang) skrypt budujący
  out/               -- wynik `zpk build` -- pliki .zpk + .zpk.json (manifest)
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

## Publikacja: `zpk schedule-release`

Tworzy Pull Request do
[`Zenit-Linux/own-repository`](https://github.com/Zenit-Linux/own-repository)
z nowym/zaktualizowanym wpisem tego pakietu:

```
zpk schedule-release                  # buduje + PR z domyślnym (top-level) wariantem
zpk schedule-release --branch=testing  # PR aktualizujący TYLKO branch "testing"
zpk schedule-release --asset=out/hello-world-1.0.0-x86_64.zpk  # użyj już zbudowanego pliku
```

Wymaga [`gh`](https://cli.github.com/) (GitHub CLI), już zalogowanego
(`gh auth login`) -- `zpk` samo nigdy nie dotyka Twoich poświadczeń,
deleguje autentykację w całości do `gh`. Bez `gh` w PATH, `zpk`
zatrzymuje się po lokalnym commicie i podaje dokładną instrukcję,
co zrobić ręcznie (`git push` + `gh pr create` / PR ręcznie na GitHubie).

### `zpk tutorial-release` -- interaktywny kreator

Dla osób, które wolą przejść przez proces pytanie-po-pytaniu zamiast
pamiętać wszystkie flagi:

```
zpk tutorial-release
ZPK_LANG=pl zpk tutorial-release   # po polsku
```

## Dlaczego `.zpk`, nie `curl | sh`

`.zpk` to format binarny z podpisanym manifestem (nazwa, wersja,
architektura, zależności, suma sha256 archiwum I każdego pliku w
środku) -- `zpm install pakiet.zpk` weryfikuje integralność przed
rozpakowaniem, w przeciwieństwie do pobrania i uruchomienia dowolnego
skryptu instalacyjnego z internetu.

## Rozwój

```
nimble install -d -y
nimble test          # testy jednostkowe (parser HCL, builder, release)
nim c -d:release --opt:speed -o:bin/zpk src/zpk.nim
```

## Licencja

GPL-3.0 -- patrz [LICENSE](LICENSE).
