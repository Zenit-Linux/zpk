import std/[os, osproc, times, algorithm, parseopt, strutils, strformat]
import ./zpkpkg/types
import ./zpkpkg/manifest
import ./zpkpkg/builder
import ./zpkpkg/release
import ./zpkpkg/tutorial
import ./zpkpkg/deps
import ./zpkpkg/versionbump
import ./zpkpkg/archive
import ./zpkpkg/signing

const zpkVersion = "0.3.0"

proc usage() =
  echo &"""
zpk {zpkVersion} — oficjalny builder pakietów .zpk dla zpm (Zenit Linux)

Użycie:
  zpk init [--dir=<ścieżka>]              Tworzy szkielet zpk.build + recipe.janet
  zpk build [FLAGI]                       Buduje .zpk z zpk.build w bieżącym katalogu
  zpk clean [FLAGI]                       Usuwa katalog wyjściowy (domyślnie ./out)
  zpk bump-version [major|minor|patch]    Podnosi package.version w zpk.build
  zpk schedule-release [FLAGI]            Otwiera PR do repozytorium own-repository
  zpk tutorial-release                    Interaktywny kreator publikacji (i18n: pl/en)
  zpk validate                            Sprawdza zpk.build bez budowania
  zpk deps                                Sprawdza status package.depends_on (best-effort)
  zpk verify <plik.zpk> [--pubkey=]       Sprawdza integralność/autentyczność pakietu
  zpk inspect <plik.zpk>                  Podgląd zawartości archiwum (rozmiary/kompresja), bez instalacji
  zpk diff <stary.zpk> <nowy.zpk>         Różnice między wersjami pakietu (z samego TOC, bez rozpakowania)
  zpk delta <stary.zpk> <nowy.zpk> <out>  Buduje mały plik delty (.zpkd) do aktualizacji bez pełnego pobierania
  zpk migrate <stary.zpk> <nowy.zpk>      Przepakowuje pre-v0.5 (tar) .zpk do formatu ZPKA v2 (wymaga `tar`)
  zpk genkey <prefiks>                    Generuje parę kluczy Ed25519 (czysty Nim, bez openssl)
  zpk version | --version | -v
  zpk help | --help | -h

Flagi `zpk build`:
  --release           Buduj dla WSZYSTKICH architektur z package.arch (domyślnie:
                       tylko architektura hosta / pierwsza z listy)
  --arch=X             Buduj tylko dla jednej, wskazanej architektury
  --out=<katalog>       Katalog wyjściowy (domyślnie: ./out)
  --verbose             Pokazuje pełne polecenia/env recipe podczas budowania
  -f, --file=<ścieżka>  Ścieżka do zpk.build (domyślnie: ./zpk.build)
  --sign-key=<ścieżka>  Podpisz zbudowany pakiet kluczem prywatnym PEM (RSA/Ed25519)
                        -- równoważne ustawieniu ZPK_SIGN_KEY w środowisku.
                        Wymaga OpenSSL >= 3.0 (używa `openssl pkeyutl`).

Flagi `zpk clean`:
  --out=<katalog>       Katalog do usunięcia (domyślnie: ./out)
  -f, --file=<ścieżka>  Ścieżka do zpk.build, względem której liczony jest ./out

Flagi `zpk bump-version`:
  major|minor|patch     Który człon semver podnieść (domyślnie: patch)
  --set=<X.Y.Z>          Ustaw wersję jawnie zamiast podnosić (ignoruje major/minor/patch)
  -f, --file=<ścieżka>   Ścieżka do zpk.build (domyślnie: ./zpk.build)

Flagi `zpk schedule-release`:
  --branch=<nazwa>       Branch w own-repository.json (stable/rolling/semi-rolling/
                          testing/...) -- pusty = wpis domyślny (top-level)
  --asset=<ścieżka>       Ścieżka do już zbudowanego .zpk -- MOŻNA podać wielokrotnie
                          (jedna architektura na wystąpienie flagi); bez tej flagi buduje
                          najpierw WSZYSTKIE architektury z package.arch
  --dry-run               Przygotuj i pokaż zmiany (klon + JSON) BEZ push/PR/upload
  --skip-upload           Nie twórz/aktualizuj GitHub Release ani nie wgrywaj assetu
                          (tylko PR do own-repository.json)
  --verbose

Flagi `zpk verify`:
  --pubkey=<ścieżka>     Klucz publiczny (natywny Ed25519 albo PEM) do weryfikacji
                         podpisu (domyślnie: zmienna środowiskowa ZPK_VERIFY_KEY)

Reprodukowalne buildy:
  SOURCE_DATE_EPOCH=<unix-timestamp> zpk build
                         Znacznik czasu w manifeście pochodzi z tej zmiennej zamiast
                         zegara -- dwa buildy tej samej zawartości z tym samym
                         SOURCE_DATE_EPOCH dają bajt-w-bajt identyczny .zpk.

Przykłady:
  zpk init && zpk build --verbose
  zpk build --release --verbose
  zpk bump-version minor
  zpk bump-version --set=2.0.0
  zpk genkey ~/.zpk/signing-key
  ZPK_SIGN_KEY=~/.zpk/signing-key.priv zpk build --release
  zpk verify out/hello-world-1.0.0-x86_64.zpk --pubkey=~/.zpk/signing-key.pub
  zpk inspect out/hello-world-1.0.0-x86_64.zpk
  zpk diff old/hello-world-1.0.0-x86_64.zpk out/hello-world-1.1.0-x86_64.zpk
  zpk delta old/hello-world-1.0.0-x86_64.zpk out/hello-world-1.1.0-x86_64.zpk update.zpkd
  zpk migrate legacy-package.zpk legacy-package-migrated.zpk
  zpk deps
  zpk schedule-release --branch=testing
  zpk schedule-release --asset=out/x-1.0.0-x86_64.zpk --asset=out/x-1.0.0-aarch64.zpk
  zpk schedule-release --dry-run
  zpk tutorial-release
  ZPK_LANG=pl zpk tutorial-release
"""

const exampleRecipeJanet = """
# recipe.janet -- przykładowy skrypt budujący pakiet zpk.
#
# Dostaje w środowisku:
#   ZPM_PACKAGE_STAGE_DIR  -- katalog, w którym MUSISZ zostawić gotowe
#                             pliki do zainstalowania, ŚCIEŻKI WZGLĘDEM "/"
#                             (np. usr/local/bin/hello)
#   ZPM_PACKAGE_NAME, ZPM_PACKAGE_VERSION, ZPM_PACKAGE_ARCH
#   ZPM_QEMU_STATIC (opcjonalnie, tylko przy budowaniu cross-arch, jeśli
#                    zpk znalazło qemu-<arch>-static w PATH)

(import os)

(def stage (os/getenv "ZPM_PACKAGE_STAGE_DIR"))
(def bin-dir (string stage "/usr/local/bin"))
(os/mkdir bin-dir)

(spit (string bin-dir "/hello-world")
      "#!/bin/sh\necho 'Hello from a zpk package!'\n")
(os/shell (string "chmod +x " bin-dir "/hello-world"))
"""

const exampleZpkBuild = """
# zpk.build -- główny plik informacyjny pakietu (format HCL).

package {
  name        = "hello-world"
  version     = "1.0.0"
  arch        = ["x86_64", "aarch64"]
  description = "Przykładowy pakiet .zpk zbudowany przez zpk"
  depends_on  = []
}

recipe {
  file = "recipe.janet"
  lang = "janet"
}

release {
  # Repo, do którego `zpk schedule-release`/`zpk tutorial-release`
  # tworzą Pull Request z nowym/aktualizowanym wpisem pakietu.
  repo       = "https://github.com/Zenit-Linux/own-repository"
  repo_file  = "repo/own-repository.json"
  # branch    = "testing"   # odkomentuj, żeby publikować pod branchem
  asset_name = "hello-world"
}
"""

proc cmdInit(dir: string) =
  createDir(dir)
  let buildPath = dir / "zpk.build"
  let recipePath = dir / "recipe.janet"
  var created = 0
  if not fileExists(buildPath):
    writeFile(buildPath, exampleZpkBuild)
    echo &"[zpk] utworzono {buildPath}"
    inc created
  if not fileExists(recipePath):
    writeFile(recipePath, exampleRecipeJanet)
    echo &"[zpk] utworzono {recipePath}"
    inc created
  if created == 0:
    echo "[zpk] zpk.build i recipe.janet już istnieją -- nic do zrobienia."
  else:
    echo "[zpk] Gotowe. Edytuj zpk.build/recipe.janet, potem: zpk build --verbose"

proc cmdValidate(buildFile: string) =
  try:
    let m = loadZpkBuild(buildFile)
    let pkgDir = parentDir(absolutePath(buildFile))
    let warnings = validateZpkBuildFull(m, pkgDir)
    if warnings.len == 0:
      echo &"[zpk] ✔ {buildFile} poprawny."
    else:
      echo &"[zpk] ⚠ {buildFile} sparsowany, ale ze zastrzeżeniami:"
      for w in warnings:
        echo &"      - {w}"
    echo &"      name={m.name} version={m.version} arch={m.arches.join(\", \")}"
    echo &"      recipe={m.recipeFile} ({m.recipeLang})"
    if m.dependsOn.len > 0:
      echo "      depends_on:"
      for (name, status) in checkDependencies(m.dependsOn):
        echo &"        - {name}: {statusLabel(status)}"
      echo "      (status zależności to best-effort -- patrz `zpk deps` i README)"
    if warnings.len > 0:
      quit(1)
  except ZpkError as e:
    stderr.writeLine("[zpk] ✘ " & e.msg)
    quit(1)

proc cmdDeps(buildFile: string) =
  var m: ZpkBuildManifest
  try:
    m = loadZpkBuild(buildFile)
  except ZpkError as e:
    stderr.writeLine("[zpk] ✘ " & e.msg)
    quit(1)
  if m.dependsOn.len == 0:
    echo &"[zpk] {m.name} nie deklaruje żadnych depends_on."
    return
  echo &"[zpk] Zależności {m.name} {m.version}:"
  var anyMissing = false
  for (name, status) in checkDependencies(m.dependsOn):
    let marker = case status
      of dsInstalled: "✔"
      of dsMissing: "✘"
      of dsUnknown: "?"
    echo &"  {marker} {name}: {statusLabel(status)}"
    if status == dsMissing: anyMissing = true
  echo ""
  echo "Uwaga: to sprawdzenie jest best-effort -- zpk pyta `zpm list --installed`," &
    " jeśli dostępne, inaczej sprawdza obecność binarki o tej nazwie w PATH."
  if anyMissing: quit(1)

proc cmdBumpVersion(buildFile, kindArg, setVersion: string) =
  var m: ZpkBuildManifest
  try:
    m = loadZpkBuild(buildFile)
  except ZpkError as e:
    stderr.writeLine("[zpk] ✘ " & e.msg)
    quit(1)

  var newVersion: string
  if setVersion.len > 0:
    if not isValidSemver(setVersion):
      stderr.writeLine(&"[zpk] ✘ '{setVersion}' nie jest poprawnym semver (oczekiwano MAJOR.MINOR.PATCH)")
      quit(1)
    newVersion = setVersion
  else:
    var kind = bkPatch
    case kindArg.toLowerAscii
    of "major": kind = bkMajor
    of "minor": kind = bkMinor
    of "patch", "": kind = bkPatch
    else:
      stderr.writeLine(&"[zpk] ✘ nieznany typ podbicia wersji '{kindArg}' (oczekiwano: major/minor/patch)")
      quit(1)
    newVersion = bumpedVersion(m.version, kind)

  let (ok, oldV, newV, message) = bumpVersionInFile(buildFile, newVersion)
  if not ok:
    stderr.writeLine("[zpk] ✘ " & message)
    quit(1)
  echo &"[zpk] ✔ {oldV} -> {newV} ({buildFile})"

proc cmdBuild(buildFile: string, releaseAll: bool, onlyArch, outDir: string, verbose: bool, signKey: string) =
  var m: ZpkBuildManifest
  try:
    m = loadZpkBuild(buildFile)
  except ZpkError as e:
    stderr.writeLine("[zpk] ✘ " & e.msg)
    quit(1)

  if signKey.len > 0:
    putEnv("ZPK_SIGN_KEY", signKey)

  let pkgDir = parentDir(absolutePath(buildFile))
  let effectiveOutDir = if outDir.len > 0: outDir else: pkgDir / "out"
  let arch = if releaseAll: "" else: (if onlyArch.len > 0: onlyArch else: m.arches[0])

  let (ok, built) = buildAll(pkgDir, m, effectiveOutDir, verbose, arch)
  if not ok:
    quit(1)
  echo &"[zpk] ✔ Zbudowano {built.len} archiwa .zpk w {effectiveOutDir}"

proc cmdClean(buildFile, outDir: string) =
  let pkgDir = parentDir(absolutePath(buildFile))
  let effectiveOutDir = if outDir.len > 0: outDir else: pkgDir / "out"
  if dirExists(effectiveOutDir):
    removeDir(effectiveOutDir)
    echo &"[zpk] ✔ usunięto {effectiveOutDir}"
  else:
    echo &"[zpk] {effectiveOutDir} nie istnieje -- nic do zrobienia."

proc cmdVerify(zpkPath, pubKey: string) =
  let (ok, messages) = verifyPackage(zpkPath, pubKey)
  for msg in messages:
    echo (if ok: "[zpk] ✔ " else: "[zpk]   ") & msg
  if ok:
    echo &"[zpk] ✔ {zpkPath} zweryfikowany pomyślnie."
  else:
    stderr.writeLine(&"[zpk] ✘ weryfikacja {zpkPath} nie powiodła się.")
    quit(1)

proc humanSize(n: uint64): string =
  if n < 1024: return $n & " B"
  if n < 1024*1024: return &"{n.float / 1024.0:.1f} KiB"
  if n < 1024*1024*1024: return &"{n.float / (1024.0*1024.0):.1f} MiB"
  &"{n.float / (1024.0*1024.0*1024.0):.1f} GiB"

proc cmdInspect(zpkPath: string) =
  ## `zpk inspect` -- podgląd zawartości archiwum BEZ instalacji: lista
  ## plików, rozmiary surowe/skompresowane, metoda kompresji, łączny
  ## współczynnik. Czyta WYŁĄCZNIE TOC (stopka archiwum), nie dotyka
  ## ładunku -- błyskawiczne nawet dla wielkich pakietów.
  if not archive.isZpkaFile(zpkPath):
    stderr.writeLine(&"[zpk] ✘ {zpkPath} nie jest archiwum w formacie ZPKA v2.")
    quit(1)
  let (ok, report, err) = archive.inspectArchive(zpkPath)
  if not ok:
    stderr.writeLine(&"[zpk] ✘ {err}")
    quit(1)
  echo &"[zpk] {zpkPath}  ({report.entries.len} plików)"
  echo ""
  var sorted = report.entries
  sorted.sort(proc(a, b: archive.InspectEntry): int = cmp(b.rawSize, a.rawSize))
  echo &"  {\"METODA\":<7} {\"SUROWO\":>10} {\"SKOMPR.\":>10} {\"WSP.\":>6}  ŚCIEŻKA"
  for e in sorted:
    let ratio = if e.rawSize > 0: (e.compSize.float / e.rawSize.float) * 100.0 else: 0.0
    echo &"  {e.methodName:<7} {humanSize(e.rawSize):>10} {humanSize(e.compSize):>10} {ratio:>5.1f}%  {e.path}"
  echo ""
  let totalRatio = if report.totalRaw > 0: (report.totalComp.float / report.totalRaw.float) * 100.0 else: 0.0
  echo &"  RAZEM: {humanSize(report.totalRaw)} -> {humanSize(report.totalComp)} ({totalRatio:.1f}%, archiwum na dysku: {humanSize(uint64(getFileSize(zpkPath)))})"

proc cmdDiff(pathA, pathB: string) =
  ## `zpk diff` -- różnice między dwiema wersjami pakietu, WYŁĄCZNIE z
  ## TOC obu archiwów (ścieżka + sha256 + rozmiar) -- bez rozpakowania
  ## jednego bajtu ładunku którejkolwiek strony.
  for p in [pathA, pathB]:
    if not archive.isZpkaFile(p):
      stderr.writeLine(&"[zpk] ✘ {p} nie jest archiwum w formacie ZPKA v2.")
      quit(1)
  let (ok, report, err) = archive.diffArchives(pathA, pathB)
  if not ok:
    stderr.writeLine(&"[zpk] ✘ {err}")
    quit(1)
  echo &"[zpk] diff {pathA} -> {pathB}"
  var added, removed, changed = 0
  for e in report.entries:
    case e.kind
    of dkAdded:
      inc added
      echo &"  + {e.path}  ({humanSize(e.newSize)})"
    of dkRemoved:
      inc removed
      echo &"  - {e.path}  ({humanSize(e.oldSize)})"
    of dkChanged:
      inc changed
      echo &"  ~ {e.path}  ({humanSize(e.oldSize)} -> {humanSize(e.newSize)})"
    of dkUnchanged:
      discard
  echo ""
  echo &"[zpk] {added} dodanych, {removed} usuniętych, {changed} zmienionych, " &
    &"{report.unchangedCount} bez zmian."

proc cmdDelta(oldPath, newPath, outPath: string) =
  ## `zpk delta` -- buduje mały plik delty (`.zpkd`) pozwalający
  ## odtworzyć `newPath` mając `oldPath` + deltę, bez przesyłania całego
  ## nowego archiwum -- pliki niezmienione (ta sama treść, wg sha256) są
  ## w delcie tylko ODNIESIENIEM do starego archiwum.
  for p in [oldPath, newPath]:
    if not archive.isZpkaFile(p):
      stderr.writeLine(&"[zpk] ✘ {p} nie jest archiwum w formacie ZPKA v2.")
      quit(1)
  let (ok, msg) = archive.buildDelta(oldPath, newPath, outPath)
  if not ok:
    stderr.writeLine(&"[zpk] ✘ {msg}")
    quit(1)
  let deltaSize = getFileSize(outPath)
  let newSize = getFileSize(newPath)
  echo &"[zpk] ✔ {outPath} ({humanSize(uint64(deltaSize))}, {msg})"
  echo &"[zpk]   dla porównania: pełne {newPath} to {humanSize(uint64(newSize))}"

proc cmdMigrate(oldZpkPath, outPath: string) =
  ## `zpk migrate` -- jednorazowe, OPT-IN przepakowanie starszego `.zpk`
  ## (tar, sprzed v0.5) do nowego formatu ZPKA v2, BEZ potrzeby
  ## przebudowywania pakietu od zera z jego oryginalnego recipe (które
  ## może już nie być pod ręką -- stary tarball to jedyne, co zostało).
  ##
  ## To JEDYNE miejsce w całym `zpk`/`zpm`, które nadal (opcjonalnie,
  ## tylko na wyraźne żądanie) korzysta z systemowego `tar` -- bo to
  ## JEDYNY sposób odczytania STAREGO formatu, którego `archive.nim`
  ## świadomie nie obsługuje (patrz uzasadnienie w `archive.nim`).
  ## Wymaga `tar` w PATH; jeśli go brak, kończy się jasnym błędem.
  if archive.isZpkaFile(oldZpkPath):
    echo &"[zpk] {oldZpkPath} jest JUŻ w formacie ZPKA v2 -- migracja niepotrzebna."
    return
  if findExe("tar").len == 0:
    stderr.writeLine("[zpk] ✘ `zpk migrate` potrzebuje systemowego `tar` do odczytania " &
      "STAREGO formatu (jedyne miejsce w zpk, które go używa) -- nie znaleziono w PATH.")
    quit(1)

  let tmpDir = getTempDir() / &"zpk-migrate-{$epochTime().int}-{getCurrentProcessId()}"
  createDir(tmpDir)
  defer: removeDir(tmpDir)
  echo &"[zpk] Rozpakowuję (tar) {oldZpkPath} do przepakowania..."
  let code = execCmd(&"tar -C {quoteShell(tmpDir)} -xf {quoteShell(oldZpkPath)}")
  if code != 0:
    stderr.writeLine(&"[zpk] ✘ `tar -xf {oldZpkPath}` nie powiodło się (kod {code}) -- " &
      "plik uszkodzony albo to nie jest archiwum tar.")
    quit(1)

  let oldManifestPath = tmpDir / ManifestFileName
  if not fileExists(oldManifestPath):
    stderr.writeLine(&"[zpk] ✘ {oldZpkPath} nie zawiera {ManifestFileName} -- to nie wygląda na pakiet .zpk.")
    quit(1)

  var toPack: seq[archive.PendingFile] = @[]
  for path in walkDirRec(tmpDir):
    let rel = path.relativePath(tmpDir)
    toPack.add archive.PendingFile(relPath: rel, absPath: path)

  # Manifest jest przepakowywany TAKI, JAKI BYŁ (w tym stary podpis, jeśli
  # istniał -- treść plików się nie zmienia, więc sha256 per plik i
  # agregat w manifeście POZOSTAJĄ poprawne; zmienia się WYŁĄCZNIE
  # kontener na dysku, nie to, co on poświadcza).
  discard archive.writeArchive(outPath, toPack)
  echo &"[zpk] ✔ {outPath} -- przepakowano do formatu ZPKA v2 " &
    &"({humanSize(uint64(getFileSize(oldZpkPath)))} -> {humanSize(uint64(getFileSize(outPath)))})"
  echo "[zpk]   Uwaga: manifest (w tym sha256/podpis, jeśli był) przeniesiony bez zmian --" &
    " poświadcza tę samą zawartość, tylko w nowym kontenerze."

proc cmdGenkey(outPrefix: string) =
  ## `zpk genkey` -- generuje nową parę kluczy Ed25519 W 100% W NIM
  ## (`ed25519.nim`, ziarno z `std/sysrand` -- bezpieczny generator
  ## systemowy), ZERO zależności od `openssl`. Zapisuje
  ## `<prefix>.priv`/`<prefix>.pub` w natywnym formacie tekstowym.
  let privPath = outPrefix & ".priv"
  let pubPath = outPrefix & ".pub"
  if fileExists(privPath) or fileExists(pubPath):
    stderr.writeLine(&"[zpk] ✘ {privPath} lub {pubPath} już istnieje -- nie nadpisuję. " &
      "Podaj inny prefiks albo usuń istniejące pliki ręcznie.")
    quit(1)
  signing.genNativeEd25519Keypair(privPath, pubPath)
  echo &"[zpk] ✔ Wygenerowano parę kluczy Ed25519 (czysty Nim, bez openssl):"
  echo &"[zpk]     prywatny: {privPath}  (trzymaj w sekrecie, chmod 600 ustawiony automatycznie)"
  echo &"[zpk]     publiczny: {pubPath}  (rozpowszechniaj -- służy do `zpk verify --pubkey=`/`zpm`)"
  echo &"[zpk]   Użycie przy budowaniu:  ZPK_SIGN_KEY={privPath} zpk build"
  echo &"[zpk]   Użycie przy weryfikacji: zpk verify plik.zpk --pubkey={pubPath}"

proc cmdScheduleRelease(buildFile, branchOverride: string, assetOverrides: seq[string],
                         verbose, dryRun, skipUpload: bool) =
  var m: ZpkBuildManifest
  try:
    m = loadZpkBuild(buildFile)
  except ZpkError as e:
    stderr.writeLine("[zpk] ✘ " & e.msg)
    quit(1)
  if branchOverride.len > 0:
    m.release.branch = branchOverride

  let pkgDir = parentDir(absolutePath(buildFile))
  var builtAssets: seq[tuple[arch, path: string]] = @[]
  if assetOverrides.len > 0:
    # Użytkownik podał gotowe pliki (jedna --asset= na architekturę) --
    # publikujemy DOKŁADNIE te, próbując odgadnąć architekturę z nazwy
    # każdego pliku (`<n>-<version>-<arch>.zpk`).
    for assetPath in assetOverrides:
      let arch = archFromPackageFileName(extractFilename(assetPath), m.name, m.version)
      if arch.len == 0:
        stderr.writeLine(&"[zpk] ⚠ nie udało się rozpoznać architektury z nazwy '{assetPath}' " &
          "-- oczekiwano formatu <n>-<version>-<arch>.zpk; pomijam ten plik.")
        continue
      builtAssets.add (arch, assetPath)
    if builtAssets.len == 0:
      stderr.writeLine("[zpk] ✘ żaden z podanych --asset nie ma rozpoznawalnej architektury w nazwie.")
      quit(1)
  else:
    # Buduje WSZYSTKIE architektury z package.arch -- wcześniej budowano
    # też wszystkie, ale do publikacji brano tylko pierwszą (built[0]).
    let (ok, built) = buildAll(pkgDir, m, pkgDir / "out", verbose, "")
    if not ok or built.len == 0:
      stderr.writeLine("[zpk] ✘ Budowanie przed publikacją nie powiodło się.")
      quit(1)
    builtAssets = built

  let (ok, message) = scheduleRelease(m, builtAssets, verbose, pkgDir, dryRun = dryRun, skipReleaseUpload = skipUpload)
  echo message
  if not ok: quit(1)

proc main() =
  var p = initOptParser(commandLineParams())
  var positional: seq[string] = @[]
  var dirOpt = ""
  var releaseAll = false
  var archOpt = ""
  var outOpt = ""
  var verbose = false
  var fileOpt = "zpk.build"
  var branchOpt = ""
  var assetOpts: seq[string] = @[]
  var signKeyOpt = ""
  var pubKeyOpt = ""
  var setVersionOpt = ""
  var dryRun = false
  var skipUpload = false

  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      positional.add key
    of cmdLongOption, cmdShortOption:
      case key
      of "dir": dirOpt = val
      of "release": releaseAll = true
      of "arch": archOpt = val
      of "out": outOpt = val
      of "verbose": verbose = true
      of "file", "f": fileOpt = val
      of "branch": branchOpt = val
      of "asset": assetOpts.add val
      of "sign-key": signKeyOpt = val
      of "pubkey": pubKeyOpt = val
      of "set": setVersionOpt = val
      of "dry-run": dryRun = true
      of "skip-upload": skipUpload = true
      of "help", "h": usage(); quit(0)
      of "version", "v": echo zpkVersion; quit(0)
      else: discard
    of cmdEnd: discard

  if positional.len == 0:
    usage()
    quit(1)

  case positional[0]
  of "init":
    cmdInit(if dirOpt.len > 0: dirOpt else: getCurrentDir())
  of "validate":
    cmdValidate(fileOpt)
  of "deps":
    cmdDeps(fileOpt)
  of "bump-version":
    let kindArg = if positional.len > 1: positional[1] else: "patch"
    cmdBumpVersion(fileOpt, kindArg, setVersionOpt)
  of "build":
    cmdBuild(fileOpt, releaseAll, archOpt, outOpt, verbose, signKeyOpt)
  of "clean":
    cmdClean(fileOpt, outOpt)
  of "verify":
    if positional.len < 2:
      stderr.writeLine("[zpk] ✘ zpk verify wymaga ścieżki do pliku .zpk")
      quit(1)
    cmdVerify(positional[1], pubKeyOpt)
  of "inspect":
    if positional.len < 2:
      stderr.writeLine("[zpk] ✘ zpk inspect wymaga ścieżki do pliku .zpk")
      quit(1)
    cmdInspect(positional[1])
  of "diff":
    if positional.len < 3:
      stderr.writeLine("[zpk] ✘ zpk diff wymaga dwóch ścieżek: <stary.zpk> <nowy.zpk>")
      quit(1)
    cmdDiff(positional[1], positional[2])
  of "delta":
    if positional.len < 4:
      stderr.writeLine("[zpk] ✘ zpk delta wymaga trzech ścieżek: <stary.zpk> <nowy.zpk> <out.zpkd>")
      quit(1)
    cmdDelta(positional[1], positional[2], positional[3])
  of "migrate":
    if positional.len < 3:
      stderr.writeLine("[zpk] ✘ zpk migrate wymaga dwóch ścieżek: <stary.zpk> <nowy.zpk>")
      quit(1)
    cmdMigrate(positional[1], positional[2])
  of "genkey":
    if positional.len < 2:
      stderr.writeLine("[zpk] ✘ zpk genkey wymaga prefiksu ścieżki (np. `zpk genkey ~/.zpk/signing-key`)")
      quit(1)
    cmdGenkey(positional[1])
  of "schedule-release":
    cmdScheduleRelease(fileOpt, branchOpt, assetOpts, verbose, dryRun, skipUpload)
  of "tutorial-release":
    runTutorialRelease()
  of "version", "--version", "-v":
    echo zpkVersion
  of "help", "--help", "-h":
    usage()
  else:
    stderr.writeLine(&"[zpk] Nieznana komenda: {positional[0]}")
    usage()
    quit(1)

when isMainModule:
  main()
