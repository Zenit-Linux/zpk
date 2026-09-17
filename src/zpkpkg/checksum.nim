import ./zsha256

## Liczenie sha256 pliku -- v0.5: CZYSTY NIM, zero procesów potomnych.
##
## Poprzednio ta funkcja odpalała po kolei `sha256sum` / `shasum -a 256` /
## `openssl dgst -sha256`, próbując znaleźć którekolwiek z nich w PATH --
## działało, ale było (a) wolniejsze (fork+exec per plik), (b) kruche na
## systemach bez ŻADNEGO z tych trzech narzędzi w PATH (np. minimalne
## obrazy kontenerowe bez coreutils). `zsha256.nim` implementuje SHA-256
## (FIPS 180-4) w 100% czystym Nim, testowane wektorami NIST (patrz
## `tests/test_core.nim`, sekcja "zsha256") -- identyczny wynik na każdej
## platformie, bez ŻADNEJ zależności zewnętrznej.
##
## Publiczne API (`sha256sumOf`, `ChecksumError`) zostało celowo
## niezmienione względem poprzedniej wersji, więc cała reszta `zpk`
## (builder.nim, signing.nim) działa bez modyfikacji.

type ChecksumError* = object of CatchableError

proc sha256sumOf*(path: string): string =
  ## Zwraca sha256 pliku `path` jako hex string (64 znaki, małe litery).
  ## Czyta plik strumieniowo (bloki 64 KiB) -- stałe zużycie pamięci
  ## niezależnie od rozmiaru pliku. Rzuca `ChecksumError`, jeśli plik nie
  ## istnieje / nie da się otworzyć (zamiast po cichu zwrócić pusty string).
  try:
    zsha256.sha256HexOfFile(path)
  except IOError as e:
    raise newException(ChecksumError, "nie można policzyć sha256 pliku '" & path & "': " & e.msg)
