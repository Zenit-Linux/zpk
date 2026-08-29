import std/[os, osproc, base64, strformat]

## Podpisywanie kryptograficzne pakietów .zpk.
##
## README od zawsze twierdził, że .zpk ma "podpisany manifest", ale
## realnie liczona była TYLKO suma sha256 -- to integralność (czy plik
## się nie uszkodził/zmienił), NIE autentyczność (czy pakiet faktycznie
## pochodzi od kogoś, kto ma klucz prywatny). Ten moduł dodaje prawdziwy
## podpis, delegując kryptografię do `openssl` (dostępne praktycznie
## wszędzie, bez dodawania zależności nimble) -- `zpk` samo nigdy nie
## generuje ani nie przechowuje kluczy, tylko z nich korzysta.
##
## Podpisywanie jest CAŁKOWICIE OPCJONALNE i sterowane zmienną
## środowiskową `ZPK_SIGN_KEY` (ścieżka do klucza prywatnego PEM,
## RSA lub Ed25519). Jeśli nieustawiona, `zpk build` działa jak
## wcześniej -- tylko sha256, bez podpisu, bez błędu.

type SigningError* = object of CatchableError

proc opensslAvailable*(): bool =
  findExe("openssl").len > 0

proc signFile*(path, privateKeyPath: string): string =
  ## Podpisuje sha256 pliku `path` kluczem prywatnym `privateKeyPath`
  ## (PEM, RSA lub Ed25519 -- `openssl dgst -sign` obsługuje oba).
  ## Zwraca podpis zakodowany base64 (jedna linia).
  if not opensslAvailable():
    raise newException(SigningError, "openssl nie jest dostępne w PATH -- wymagane do podpisywania")
  if not fileExists(privateKeyPath):
    raise newException(SigningError, &"nie znaleziono klucza prywatnego: {privateKeyPath}")
  let sigPath = path & ".sig.tmp"
  defer:
    if fileExists(sigPath): removeFile(sigPath)
  let cmd = "openssl dgst -sha256 -sign " & quoteShell(privateKeyPath) &
    " -out " & quoteShell(sigPath) & " " & quoteShell(path)
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    raise newException(SigningError, &"podpisywanie {path} nie powiodło się: {output}")
  let raw = readFile(sigPath)
  # openssl zwraca surowe bajty podpisu -- zakoduj do base64, żeby dało
  # się bezpiecznie umieścić w manifest.json obok reszty metadanych.
  result = encode(raw)

proc verifyFile*(path, publicKeyPath, signatureBase64: string): bool =
  ## Weryfikuje podpis `signatureBase64` (jak zwrócony przez `signFile`)
  ## pliku `path` względem klucza publicznego `publicKeyPath`.
  if not opensslAvailable(): return false
  if not fileExists(publicKeyPath): return false
  let sigPath = path & ".verify.tmp"
  defer:
    if fileExists(sigPath): removeFile(sigPath)
  try:
    writeFile(sigPath, decode(signatureBase64))
  except CatchableError:
    return false
  let cmd = "openssl dgst -sha256 -verify " & quoteShell(publicKeyPath) &
    " -signature " & quoteShell(sigPath) & " " & quoteShell(path)
  let (_, code) = execCmdEx(cmd)
  code == 0
