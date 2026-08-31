import std/[os, osproc, base64, strformat, strutils]

## Podpisywanie kryptograficzne pakietów .zpk.
##
## README od zawsze twierdził, że .zpk ma "podpisany manifest", ale
## realnie liczona była TYLKO suma sha256 -- to integralność, NIE
## autentyczność. Ten moduł dodaje prawdziwy podpis przez `openssl`.
##
## WAŻNE (znalezione dopiero przy realnym teście z prawdziwym kluczem,
## nie tylko przez czytanie kodu): `openssl dgst -sign` DZIAŁA dla RSA
## (i ECDSA), ale dla Ed25519 kończy się błędem
## "Key type not supported for this operation" -- Ed25519 w OpenSSL 3.x
## NIE wspiera trybu "podpisz skrót" (bo Ed25519 podpisuje CAŁĄ
## wiadomość wewnętrznie, nie zewnętrznie policzony hash). Właściwa
## komenda dla Ed25519 to `openssl pkeyutl -sign -rawin` (flaga
## `-rawin` wymaga OpenSSL >= 3.0). Zweryfikowane ręcznie:
##
##   RSA:     openssl dgst -sha256 -sign key.pem -out sig plik      -> OK
##            openssl dgst -sha256 -verify pub.pem -signature sig plik -> OK
##   Ed25519: openssl dgst -sha256 -sign key.pem ...                -> "Key type not supported"
##            openssl pkeyutl -sign -inkey key.pem -rawin -in plik  -> OK
##            openssl pkeyutl -verify -pubin -inkey pub.pem -rawin -in plik -sigfile sig -> OK
##
## `signFile`/`verifyFile` wykrywają typ klucza (`openssl pkey ... -text
## -noout`, pierwsza linia zawiera "Ed25519" dla kluczy Ed25519) i
## wybierają odpowiednią komendę automatycznie -- użytkownik nie musi
## nic wiedzieć o tej różnicy.
##
## Podpisywanie jest CAŁKOWICIE OPCJONALNE, sterowane `ZPK_SIGN_KEY`
## (ścieżka do klucza prywatnego PEM). Bez niej -- tylko sha256, jak
## wcześniej.

type SigningError* = object of CatchableError

type KeyKind* = enum
  kkRsaOrEc   ## dgst -sign/-verify (RSA, ECDSA -- "streaming digest")
  kkEd25519   ## pkeyutl -sign/-verify -rawin ("podpisz całą wiadomość")

proc opensslAvailable*(): bool =
  findExe("openssl").len > 0

proc detectKeyKind(keyPath: string, isPublic: bool): KeyKind =
  ## Uruchamia `openssl pkey [-pubin] -in <klucz> -text -noout` i
  ## sprawdza pierwszą linię wyjścia -- dla Ed25519 zaczyna się od
  ## "ED25519 Private-Key:"/"ED25519 Public-Key:", dla RSA/EC od
  ## czegoś innego (np. "Private-Key: (2048 bit, 2 primes)").
  let pubinFlag = if isPublic: "-pubin " else: ""
  let cmd = &"openssl pkey {pubinFlag}-in {quoteShell(keyPath)} -text -noout"
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    raise newException(SigningError, &"nie udało się odczytać typu klucza {keyPath}: {output}")
  let firstLine = output.splitLines()[0]
  if "ed25519" in firstLine.toLowerAscii:
    kkEd25519
  else:
    kkRsaOrEc

proc signFile*(path, privateKeyPath: string): string =
  ## Podpisuje `path` kluczem prywatnym `privateKeyPath` (PEM, RSA/EC
  ## przez `dgst -sign`, Ed25519 przez `pkeyutl -sign -rawin` -- patrz
  ## komentarz na górze pliku). Zwraca podpis base64 (jedna linia).
  if not opensslAvailable():
    raise newException(SigningError, "openssl nie jest dostępne w PATH -- wymagane do podpisywania")
  if not fileExists(privateKeyPath):
    raise newException(SigningError, &"nie znaleziono klucza prywatnego: {privateKeyPath}")

  let kind = detectKeyKind(privateKeyPath, isPublic = false)
  let sigPath = path & ".sig.tmp"
  defer:
    if fileExists(sigPath): removeFile(sigPath)

  let cmd = case kind
    of kkEd25519:
      &"openssl pkeyutl -sign -inkey {quoteShell(privateKeyPath)} -rawin " &
        &"-in {quoteShell(path)} -out {quoteShell(sigPath)}"
    of kkRsaOrEc:
      &"openssl dgst -sha256 -sign {quoteShell(privateKeyPath)} " &
        &"-out {quoteShell(sigPath)} {quoteShell(path)}"

  let (output, code) = execCmdEx(cmd)
  if code != 0:
    raise newException(SigningError, &"podpisywanie {path} nie powiodło się: {output}")
  let raw = readFile(sigPath)
  result = encode(raw)

proc verifyFile*(path, publicKeyPath, signatureBase64: string): bool =
  ## Weryfikuje podpis `signatureBase64` (jak zwrócony przez `signFile`)
  ## pliku `path` względem klucza publicznego `publicKeyPath`. Wybiera
  ## `dgst -verify` albo `pkeyutl -verify -rawin` wg typu klucza --
  ## tak samo jak `signFile` dobiera odpowiednią komendę do podpisywania.
  if not opensslAvailable(): return false
  if not fileExists(publicKeyPath): return false

  var kind: KeyKind
  try:
    kind = detectKeyKind(publicKeyPath, isPublic = true)
  except SigningError:
    return false

  let sigPath = path & ".verify.tmp"
  defer:
    if fileExists(sigPath): removeFile(sigPath)
  try:
    writeFile(sigPath, decode(signatureBase64))
  except CatchableError:
    return false

  let cmd = case kind
    of kkEd25519:
      &"openssl pkeyutl -verify -pubin -inkey {quoteShell(publicKeyPath)} -rawin " &
        &"-in {quoteShell(path)} -sigfile {quoteShell(sigPath)}"
    of kkRsaOrEc:
      &"openssl dgst -sha256 -verify {quoteShell(publicKeyPath)} " &
        &"-signature {quoteShell(sigPath)} {quoteShell(path)}"

  let (_, code) = execCmdEx(cmd)
  code == 0
