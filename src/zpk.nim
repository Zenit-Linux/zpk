import std/[os, parseopt, strutils, strformat]
import ./zpkpkg/types
import ./zpkpkg/manifest
import ./zpkpkg/builder
import ./zpkpkg/release
import ./zpkpkg/tutorial
import ./zpkpkg/deps
import ./zpkpkg/versionbump

const zpkVersion = "0.2.0"

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
  --pubkey=<ścieżka>     Klucz publiczny PEM do weryfikacji podpisu (domyślnie:
                         zmienna środowiskowa ZPK_VERIFY_KEY)

Przykłady:
  zpk init && zpk build --verbose
  zpk build --release --verbose
  zpk bump-version minor
  zpk bump-version --set=2.0.0
  ZPK_SIGN_KEY=~/.zpk/signing-key.pem zpk build --release
  zpk verify out/hello-world-1.0.0-x86_64.zpk --pubkey=~/.zpk/signing-key.pub
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
