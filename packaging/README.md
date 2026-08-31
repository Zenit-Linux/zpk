# packaging/

WCZEŚNIEJ ten katalog nie istniał -- `zpk` umiało budować pakiety `.zpk`
z CUDZYCH projektów, ale nie miało własnej "instrukcji" pozwalającej
zapakować SAMO SIEBIE jako pakiet `.zpk` instalowalny przez `zpm`
(zamiast wyłącznie jako gołą binarkę z GitHub Releases).

## Co tu jest

* `zpk.build` -- manifest pakietu "zpk" (ten sam format, którego `zpk`
  wymaga od KAŻDEGO innego pakietu -- patrz README repo głównego).
* `recipe.janet` -- skrypt budujący: woła `nimble buildRelease` w katalogu
  głównym repo i kopiuje wynikową binarkę do
  `usr/local/bin/zpk` wewnątrz stage dir.

## Użycie

Do zbudowania `zpk` jako `.zpk` potrzebujesz JUŻ DZIAŁAJĄCEGO `zpk`
(np. pobranego z Releases, albo zbudowanego wcześniej przez `nimble
buildRelease` w tej samej sesji):

```
nimble buildRelease              # produkuje bin/zpk (zwykła binarka)
cd packaging
../bin/zpk validate
../bin/zpk build --verbose       # zbuduje packaging/out/zpk-X.Y.Z-<arch>.zpk
../bin/zpk verify out/zpk-X.Y.Z-<arch>.zpk
```

Wynikowy plik `.zpk` instaluje się dokładnie tak samo jak każdy inny
pakiet:

```
zpm install packaging/out/zpk-X.Y.Z-<arch>.zpk
```

## Dlaczego `recipe.janet`, nie `recipe.sh`

Od v0.4 KAŻDY recipe w tym repo, włącznie z tym, którym `zpk` pakuje
SAMO SIEBIE, jest w Janet -- wcześniej ten jeden katalog był jedynym
miejscem w projekcie, gdzie `recipe.lang = "sh"` (uzasadnienie: `zpk`
samo jest napisane w Nim i buduje się przez `nimble`, więc "uruchom
jedną komendę budującą i skopiuj wynik" wydawało się prostsze w gołym
`sh` niż w Janet). To był wyjątek od reguły, nie fundamentalne
ograniczenie: `recipe.janet` woła dokładnie te same polecenia
(`nimble buildRelease`, `chmod`) przez `os/shell`, tylko z poziomu
Janet zamiast bezpośrednio z powłoki -- `zpk` parser recipe nadal
przyjmuje DOWOLNY `recipe.lang` (to zostaje jako ogólna możliwość dla
cudzych pakietów), ale własny recipe zpk już z niej nie korzysta.

## Zmienna `ZPK_PACKAGING_PREBUILT_BIN`

Jeśli binarka `zpk` została już zbudowana wcześniej w tym samym biegu
(np. w CI, gdzie `nimble buildRelease` i tak już się wykonało jako
osobny krok), ustaw `ZPK_PACKAGING_PREBUILT_BIN=<ścieżka>` przed
`zpk build`, żeby `recipe.janet` nie kompilowało po raz drugi:

```
nimble buildRelease
ZPK_PACKAGING_PREBUILT_BIN="$(pwd)/bin/zpk" ../bin/zpk build --verbose
```

## Wersjonowanie

`package.version` w `zpk.build` MUSI być ręcznie zsynchronizowane z
`version` w `../zpk.nimble` i stałą `zpkVersion` w `../src/zpk.nim` --
HCL nie ma wyrażeń ani odwołań między plikami. Przy podnoszeniu wersji
`zpk`, po zaktualizowaniu tamtych dwóch miejsc, użyj samego `zpk` na
sobie:

```
cd packaging
../bin/zpk bump-version --set=X.Y.Z
```
