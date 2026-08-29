import std/[os, osproc, strutils]

## Przenośne liczenie sha256 pliku.
##
## Poprzednio `zpk` wołało WYŁĄCZNIE `sha256sum` (pakiet coreutils) --
## to działa na typowym Linuksie, ale nie istnieje domyślnie na macOS
## (tam jest `shasum -a 256`) ani na wielu minimalnych/BSD-podobnych
## środowiskach. Zamiast twardej zależności od jednego narzędzia,
## próbujemy po kolei kilka powszechnie dostępnych opcji i używamy
## pierwszej, która faktycznie jest w PATH -- `zpk` (i pakiety przez
## nie budowane) dają się dzięki temu uruchomić poza Linuksem.

type ChecksumError* = object of CatchableError

proc runAndTakeFirstToken(exe: string, args: seq[string]): string =
  let out1 = execProcess(exe, args = args, options = {poUsePath})
  if out1.len == 0: return ""
  # `sha256sum`/`shasum` drukują "<hash>  <ścieżka>"; `openssl dgst` bez
  # `-r` drukuje "SHA256(<ścieżka>)= <hash>" -- obsłuż oba formaty.
  let line = out1.splitLines()[0].strip()
  if line.len == 0: return ""
  if '=' in line:
    return line.rsplit('=', maxsplit = 1)[^1].strip()
  return line.split(' ')[0].strip()

proc sha256sumOf*(path: string): string =
  ## Zwraca sha256 pliku `path` jako hex string (64 znaki, małe litery),
  ## albo rzuca `ChecksumError`, jeśli żadne ze znanych narzędzi nie jest
  ## dostępne w PATH (zamiast po cichu zwrócić pusty string, co wcześniej
  ## kończyło się manifestem z sha256="" bez żadnego ostrzeżenia).
  if findExe("sha256sum").len > 0:
    let h = runAndTakeFirstToken("sha256sum", @[path])
    if h.len == 64: return h
  if findExe("shasum").len > 0:
    let h = runAndTakeFirstToken("shasum", @["-a", "256", path])
    if h.len == 64: return h
  if findExe("openssl").len > 0:
    # `-r` daje format "<hash>  <ścieżka>", spójny z sha256sum/shasum.
    let h = runAndTakeFirstToken("openssl", @["dgst", "-sha256", "-r", path])
    if h.len == 64: return h
  raise newException(ChecksumError,
    "nie znaleziono żadnego narzędzia do liczenia sha256 w PATH " &
    "(wypróbowano: sha256sum, shasum, openssl) -- zainstaluj jedno z nich")
