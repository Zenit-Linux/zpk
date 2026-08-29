import std/[os, strutils, strformat]
import ./types
import ./manifest
import ./builder
import ./release
import ./i18n

## `zpk tutorial-release` -- "tui masz tam pytania odpowiedzi mozesz sobie
## wyszukac wszystko szczegolowo opisane i mozna rowniez zmieniac jezyki"
## (cytat z wymagań). To jest interaktywny wizard oparty na pytaniach w
## terminalu (nie pełnoekranowe ncurses -- świadomie: najprostsza forma,
## która działa identycznie w KAŻDYM terminalu/CI-log bez zależności od
## biblioteki TUI, a i tak realizuje "pytania -> odpowiedzi -> publikacja").
## Język: ZPK_LANG=pl|en (patrz i18n.nim) -- można zmienić PRZED
## uruchomieniem, albo w trakcie odpowiadając na pierwsze pytanie.

proc ask(promptKey: string, lang: string): string =
  stdout.write("? " & t(promptKey, lang) & "\n> ")
  stdout.flushFile()
  result = readLine(stdin).strip()

proc askYesNo(promptKey: string, lang: string, defaultYes: bool): bool =
  let raw = ask(promptKey, lang).toLowerAscii
  if raw.len == 0: return defaultYes
  raw in ["y", "yes", "t", "tak"]

proc runTutorialRelease*() =
  let lang = detectLang()
  echo "=== zpk tutorial-release ==="
  echo t("welcome", lang)
  echo ""
  echo "(ZPK_LANG=pl|en -- set before running to change language)"
  echo ""

  let pkgDirRaw = ask("ask_pkg_dir", lang)
  let pkgDir = if pkgDirRaw.len > 0: pkgDirRaw else: getCurrentDir()
  let buildFilePath = pkgDir / "zpk.build"

  var m: ZpkBuildManifest
  try:
    m = loadZpkBuild(buildFilePath)
  except ZpkError as e:
    stderr.writeLine("✘ " & e.msg)
    return

  echo &"\n>> {m.name} {m.version} ({m.arches.join(\", \")})"
  if m.description.len > 0: echo "   " & m.description
  echo ""

  var builtAssets: seq[tuple[arch, path: string]] = @[]
  if askYesNo("ask_build_first", lang, true):
    echo t("building", lang)
    let outDir = pkgDir / "out"
    let (ok, built) = buildAll(pkgDir, m, outDir, verbose = false)
    if not ok or built.len == 0:
      stderr.writeLine("✘ " & t("build_failed", lang))
      return
    builtAssets = built
    echo &"✔ {built.len} archiwa .zpk zbudowane w {outDir}"
  else:
    # Bez budowania teraz -- zakładamy nazwy plików wg konwencji dla
    # WSZYSTKICH architektur z package.arch (mogą już istnieć z
    # wcześniejszego `zpk build --release`); ostrzegamy, jeśli którychś
    # brakuje, zamiast po cichu publikować URL wskazujący donikąd.
    for arch in m.arches:
      let candidate = pkgDir / "out" / packageFileName(m.name, m.version, arch)
      if fileExists(candidate):
        builtAssets.add (arch, candidate)
      else:
        stderr.writeLine(&"⚠ brak {candidate} -- pomijam architekturę '{arch}' przy publikacji")
    if builtAssets.len == 0:
      stderr.writeLine("✘ nie znaleziono żadnego wcześniej zbudowanego pliku .zpk w ./out -- " &
        "uruchom `zpk build` albo odpowiedz \"tak\" na poprzednie pytanie.")
      return

  let branch = ask("ask_branch", lang)
  var mCopy = m
  mCopy.release.branch = branch

  echo ""
  if not askYesNo("ask_confirm_pr", lang, false):
    echo t("pr_skipped", lang)
    echo t("goodbye", lang)
    return

  if findExe("gh").len == 0:
    echo t("gh_missing", lang)

  let (ok, message) = scheduleRelease(mCopy, builtAssets, verbose = false, pkgDir = pkgDir)
  echo ""
  if ok:
    echo t("pr_created", lang)
  echo message
  echo ""
  echo t("goodbye", lang)
