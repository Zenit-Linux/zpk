# build.janet
#
# Ten plik NIE jest używany przez `zpk` do budowania SAMEGO SIEBIE --
# `zpk` to program w Nim, budowany przez `nimble buildRelease` (patrz
# zpk.nimble) albo bezpośrednio `nim c -d:release src/zpk.nim`.
#
# Jest tu jako REZERWACJA/PRZYKŁAD konwencji Zenit Linux: pakiety .zpk
# budowane PRZEZ `zpk` używają domyślnie recipe w Janet (`recipe.janet`,
# patrz `zpk init` / zpkpkg/tutorial.nim). Ten plik pokazuje samą nazwę
# i miejsce, jakiego `zpk` oczekiwałby, GDYBY `zpk` samo było pakowane
# jako pakiet .zpk przez inną instancję `zpk` (tzw. "self-hosting") --
# obecnie tak NIE jest: `zpk` jest dystrybuowane jako gotowa binarka
# przez GitHub Releases (patrz .github/workflows/build-zpk.yml), nie
# jako pakiet .zpk.
#
# Był wcześniej całkowicie pusty bez żadnego wyjaśnienia -- zostawiony
# świadomie (nie usunięty), bo referencje do "recipe.janet"/konwencji
# Janet w README i zpkpkg/tutorial.nim zakładają, że ten plik istnieje
# jako punkt odniesienia. Jeśli w przyszłości `zpk` zacznie pakować
# samo siebie jako .zpk, treść tego pliku powinna zostać zastąpiona
# faktycznym recipe (patrz przykład w `zpk init` -> recipe.janet).
