import std/[os, parseopt, strutils, strformat]
import ./zpkpkg/types
import ./zpkpkg/manifest
import ./zpkpkg/builder
import ./zpkpkg/release
import ./zpkpkg/tutorial

const zpkVersion = "0.1.0"

proc usage() =
  echo &"""
zpk {zpkVersion} — oficjalny builder pakietów .zpk dla zpm (Zenit Linux)

Użycie:
  zpk init [--dir=<ścieżka>]           Tworzy szkielet zpk.build + recipe.janet
  zpk build [FLAGI]                    Buduje .zpk z zpk.build w bieżącym katalogu
  zpk schedule-release [FLAGI]         Otwiera PR do repozytorium own-repository
  zpk tutorial-release                 Interaktywny kreator publikacji (i18n: pl/en)
  zpk validate                         Sprawdza zpk.build bez budowania
  zpk version | --version | -v
  zpk help | --help | -h

Flagi `zpk build`:
  --release           Buduj dla WSZYSTKICH architektur z package.arch (domyślnie:
                       tylko architektura hosta / pierwsza z listy)
  --arch=X             Buduj tylko dla jednej, wskazanej architektury
  --out=<katalog>       Katalog wyjściowy (domyślnie: ./out)
  --verbose             Pokazuje pełne polecenia/env recipe podczas budowania
  -f, --file=<ścieżka>  Ścieżka do zpk.build (domyślnie: ./zpk.build)

Flagi `zpk schedule-release`:
  --branch=<nazwa>       Branch w own-repository.json (stable/rolling/semi-rolling/
                          testing/...) -- pusty = wpis domyślny (top-level)
  --asset=<ścieżka>       Ścieżka do już zbudowanego .zpk (domyślnie: buduje najpierw)
  --verbose

Przykłady:
  zpk init && zpk build --verbose
  zpk build --release --verbose
  zpk schedule-release --branch=testing
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
    echo &"[zpk] ✔ {buildFile} poprawny."
    echo &"      name={m.name} version={m.version} arch={m.arches.join(\", \")}"
    echo &"      recipe={m.recipeFile} ({m.recipeLang})"
  except ZpkError as e:
    stderr.writeLine("[zpk] ✘ " & e.msg)
    quit(1)

proc cmdBuild(buildFile: string, releaseAll: bool, onlyArch, outDir: string, verbose: bool) =
  var m: ZpkBuildManifest
  try:
    m = loadZpkBuild(buildFile)
  except ZpkError as e:
    stderr.writeLine("[zpk] ✘ " & e.msg)
    quit(1)

  let pkgDir = parentDir(absolutePath(buildFile))
  let effectiveOutDir = if outDir.len > 0: outDir else: pkgDir / "out"
  let arch = if releaseAll: "" else: (if onlyArch.len > 0: onlyArch else: m.arches[0])

  let (ok, built) = buildAll(pkgDir, m, effectiveOutDir, verbose, arch)
  if not ok:
    quit(1)
  echo &"[zpk] ✔ Zbudowano {built.len} archiwa .zpk w {effectiveOutDir}"

proc cmdScheduleRelease(buildFile, branchOverride, assetOverride: string, verbose: bool) =
  var m: ZpkBuildManifest
  try:
    m = loadZpkBuild(buildFile)
  except ZpkError as e:
    stderr.writeLine("[zpk] ✘ " & e.msg)
    quit(1)
  if branchOverride.len > 0:
    m.release.branch = branchOverride

  var assetPath = assetOverride
  let pkgDir = parentDir(absolutePath(buildFile))
  if assetPath.len == 0:
    let (ok, built) = buildAll(pkgDir, m, pkgDir / "out", verbose, "")
    if not ok or built.len == 0:
      stderr.writeLine("[zpk] ✘ Budowanie przed publikacją nie powiodło się.")
      quit(1)
    assetPath = built[0].path

  let (ok, message) = scheduleRelease(m, assetPath, verbose, pkgDir)
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
  var assetOpt = ""

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
      of "asset": assetOpt = val
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
  of "build":
    cmdBuild(fileOpt, releaseAll, archOpt, outOpt, verbose)
  of "schedule-release":
    cmdScheduleRelease(fileOpt, branchOpt, assetOpt, verbose)
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
