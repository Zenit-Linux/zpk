import std/[os, osproc, base64, strformat, strutils]
import ./ed25519
import std/sysrand

## Podpisywanie kryptograficzne pakietów .zpk.
##
## README od zawsze twierdził, że .zpk ma "podpisany manifest", ale
## realnie liczona była TYLKO suma sha256 -- to integralność, NIE
## autentyczność. Ten moduł dodaje prawdziwy podpis -- DWIEMA drogami:
##
## 1. **Natywny Ed25519** (`zpk genkey`, klucze "-----BEGIN ZPK NATIVE
##    ED25519...") -- w 100% czysty Nim (`ed25519.nim`), ZERO zależności
##    od `openssl`. To domyślna, zalecana droga od v0.6 -- zamyka
##    ostatnią lukę zależności zewnętrznej w całym `zpk`/`zpm`.
## 2. **PEM przez `openssl`** (RSA/EC/OpenSSL-Ed25519) -- zachowane dla
##    zgodności wstecznej z istniejącymi kluczami/łańcuchami zaufania,
##    które ktoś już ma (np. klucz RSA z firmowego HSM/CA). Wymaga
##    `openssl` w PATH -- jak wcześniej.
##
## `signFile`/`verifyFile` rozpoznają format klucza PO PIERWSZEJ LINII
## pliku (`-----BEGIN ZPK NATIVE ED25519 ...` vs cokolwiek innego = PEM)
## i wybierają odpowiednią ścieżkę automatycznie -- użytkownik nie musi
## nic wiedzieć o tej różnicy poza tym, którego polecenia użył do
## wygenerowania klucza (`zpk genkey` -> natywny, `openssl genpkey` ->
## PEM).
##
## Podpisywanie jest CAŁKOWICIE OPCJONALNE, sterowane `ZPK_SIGN_KEY`
## (ścieżka do klucza prywatnego). Bez niej -- tylko sha256, jak wcześniej.

type SigningError* = object of CatchableError

type KeyKind* = enum
  kkRsaOrEc     ## dgst -sign/-verify (RSA, ECDSA -- "streaming digest")
  kkEd25519Pem  ## pkeyutl -sign/-verify -rawin ("podpisz całą wiadomość")
  kkEd25519Native ## czysty Nim, zero openssl (patrz ed25519.nim)

const
  NativePrivateHeader = "-----BEGIN ZPK NATIVE ED25519 PRIVATE KEY-----"
  NativePrivateFooter = "-----END ZPK NATIVE ED25519 PRIVATE KEY-----"
  NativePublicHeader = "-----BEGIN ZPK NATIVE ED25519 PUBLIC KEY-----"
  NativePublicFooter = "-----END ZPK NATIVE ED25519 PUBLIC KEY-----"

proc opensslAvailable*(): bool =
  findExe("openssl").len > 0

proc isNativeKeyFile(path: string): bool =
  if not fileExists(path): return false
  try:
    let firstLine = readFile(path).splitLines()[0].strip()
    firstLine == NativePrivateHeader or firstLine == NativePublicHeader
  except CatchableError:
    false

proc readNativeKeyBody(path: string): string =
  ## Wyciąga base64 pomiędzy nagłówkiem a stopką (ignoruje białe znaki),
  ## dekoduje do surowych 32 bajtów. Rzuca przy złym formacie.
  let lines = readFile(path).splitLines()
  var b64 = ""
  for i in 1 ..< lines.len:
    let l = lines[i].strip()
    if l.startsWith("-----END"): break
    b64.add l
  try:
    result = decode(b64)
  except CatchableError:
    raise newException(SigningError, &"nie udało się zdekodować klucza natywnego z {path}")
  if result.len != 32:
    raise newException(SigningError, &"klucz natywny w {path} ma nieprawidłowy rozmiar ({result.len}, oczekiwano 32)")

proc genNativeEd25519Keypair*(privPath, pubPath: string) =
  ## Generuje nową parę kluczy Ed25519 (ziarno losowe z `std/sysrand`,
  ## bezpiecznego generatora systemowego -- `getrandom`/`arc4random`/
  ## `CryptGenRandom` zależnie od platformy, NIE `std/random`) i zapisuje
  ## w natywnym formacie tekstowym (base64 + nagłówek/stopka, czytelne
  ## jak PEM, ale jawnie oznaczone jako format `zpk`, nie X.509/PKCS8).
  let seedBytes = sysrand.urandom(32)
  var seed = ""
  for b in seedBytes: seed.add char(b)
  let pub = ed25519.ed25519DerivePublicKey(seed)

  var privOut = NativePrivateHeader & "\n"
  privOut.add encode(seed)
  privOut.add "\n" & NativePrivateFooter & "\n"
  writeFile(privPath, privOut)
  when defined(posix):
    discard execCmdEx(&"chmod 600 {quoteShell(privPath)}")  # klucz prywatny: tylko właściciel

  var pubOut = NativePublicHeader & "\n"
  pubOut.add encode(pub)
  pubOut.add "\n" & NativePublicFooter & "\n"
  writeFile(pubPath, pubOut)

proc detectKeyKind(keyPath: string, isPublic: bool): KeyKind =
  if isNativeKeyFile(keyPath):
    return kkEd25519Native
  if not opensslAvailable():
    raise newException(SigningError, &"{keyPath} wygląda na klucz PEM, ale openssl nie jest dostępne w PATH " &
      "(natywne klucze zpk zaczynają się od \"" & NativePrivateHeader & "\" -- użyj `zpk genkey`, żeby uniknąć openssl)")
  let pubinFlag = if isPublic: "-pubin " else: ""
  let cmd = &"openssl pkey {pubinFlag}-in {quoteShell(keyPath)} -text -noout"
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    raise newException(SigningError, &"nie udało się odczytać typu klucza {keyPath}: {output}")
  let firstLine = output.splitLines()[0]
  if "ed25519" in firstLine.toLowerAscii:
    kkEd25519Pem
  else:
    kkRsaOrEc

proc signFile*(path, privateKeyPath: string): string =
  ## Podpisuje `path` kluczem prywatnym `privateKeyPath`. Wykrywa
  ## automatycznie: natywny Ed25519 (czysty Nim) / Ed25519 PEM (openssl
  ## pkeyutl) / RSA lub EC PEM (openssl dgst). Zwraca podpis base64.
  if not fileExists(privateKeyPath):
    raise newException(SigningError, &"nie znaleziono klucza prywatnego: {privateKeyPath}")

  let kind = detectKeyKind(privateKeyPath, isPublic = false)

  case kind
  of kkEd25519Native:
    let seed = readNativeKeyBody(privateKeyPath)
    let content = readFile(path)
    let sig = ed25519.ed25519Sign(seed, content)
    return encode(sig)
  of kkEd25519Pem, kkRsaOrEc:
    if not opensslAvailable():
      raise newException(SigningError, "openssl nie jest dostępne w PATH -- wymagane do podpisywania kluczem PEM")
    let sigPath = path & ".sig.tmp"
    defer:
      if fileExists(sigPath): removeFile(sigPath)
    let cmd = case kind
      of kkEd25519Pem:
        &"openssl pkeyutl -sign -inkey {quoteShell(privateKeyPath)} -rawin " &
          &"-in {quoteShell(path)} -out {quoteShell(sigPath)}"
      of kkRsaOrEc:
        &"openssl dgst -sha256 -sign {quoteShell(privateKeyPath)} " &
          &"-out {quoteShell(sigPath)} {quoteShell(path)}"
      of kkEd25519Native: ""  # nieosiagalne (obsluzone wyzej)
    let (output, code) = execCmdEx(cmd)
    if code != 0:
      raise newException(SigningError, &"podpisywanie {path} nie powiodło się: {output}")
    let raw = readFile(sigPath)
    return encode(raw)

proc verifyFile*(path, publicKeyPath, signatureBase64: string): bool =
  ## Weryfikuje podpis `signatureBase64` (jak zwrócony przez `signFile`)
  ## pliku `path` względem klucza publicznego `publicKeyPath`. Wykrywa
  ## typ klucza tak samo jak `signFile`.
  if not fileExists(publicKeyPath): return false

  var kind: KeyKind
  try:
    kind = detectKeyKind(publicKeyPath, isPublic = true)
  except SigningError:
    return false

  case kind
  of kkEd25519Native:
    try:
      let pub = readNativeKeyBody(publicKeyPath)
      let sig = decode(signatureBase64)
      if sig.len != 64: return false
      let content = readFile(path)
      return ed25519.ed25519Verify(pub, content, sig)
    except CatchableError:
      return false
  of kkEd25519Pem, kkRsaOrEc:
    if not opensslAvailable(): return false
    let sigPath = path & ".verify.tmp"
    defer:
      if fileExists(sigPath): removeFile(sigPath)
    try:
      writeFile(sigPath, decode(signatureBase64))
    except CatchableError:
      return false
    let cmd = case kind
      of kkEd25519Pem:
        &"openssl pkeyutl -verify -pubin -inkey {quoteShell(publicKeyPath)} -rawin " &
          &"-in {quoteShell(path)} -sigfile {quoteShell(sigPath)}"
      of kkRsaOrEc:
        &"openssl dgst -sha256 -verify {quoteShell(publicKeyPath)} " &
          &"-signature {quoteShell(sigPath)} {quoteShell(path)}"
      of kkEd25519Native: ""  # nieosiagalne
    let (_, code) = execCmdEx(cmd)
    return code == 0
