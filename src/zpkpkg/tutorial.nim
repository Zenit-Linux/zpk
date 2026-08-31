import std/[os, strutils, strformat]
import ./types
import ./manifest
import ./builder
import ./release
import ./i18n

## `zpk tutorial-release` -- interaktywny kreator w terminalu (pytanie
## po pytaniu), z wyborem języka przez ZPK_LANG=pl|en (patrz i18n.nim).
##
## `input`/`output` są PARAMETRAMI (domyślnie prawdziwe stdin/stdout) --
## nie odwołujemy się do globalnych `stdin`/`stdout` bezpośrednio
## wewnątrz logiki, tylko przekazujemy je jawnie przez cały wywołań
## łańcuch. Dzięki temu `runTutorialRelease` można przetestować
## end-to-end (podając plik z "odpowiedziami" jako `input` i przechwytując
## `output`), bez podmieniania globalnego stdin procesu -- wcześniej
## kreator był kompletnie nietestowalny.

proc ask(promptKey: string, lang: string, input, output: File): string =
  output.write("? " & t(promptKey, lang) & "\n> ")
  output.flushFile()
  result = (if input.endOfFile: "" else: readLine(input)).strip()

proc askYesNo(promptKey: string, lang: string, defaultYes: bool, input, output: File): bool =
  let raw = ask(promptKey, lang, input, output).toLowerAscii
  if raw.len == 0: return defaultYes
  raw in ["y", "yes", "t", "tak"]

proc runTutorialRelease*(input: File = stdin, output: File = stdout, pkgDirOverride: string = "") =
  let lang = detectLang()
  output.writeLine "=== zpk tutorial-release ==="
  output.writeLine t("welcome", lang)
  output.writeLine ""
  output.writeLine "(ZPK_LANG=pl|en -- set before running to change language)"
  output.writeLine ""

  let pkgDirRaw = ask("ask_pkg_dir", lang, input, output)
  let pkgDir = if pkgDirRaw.len > 0: pkgDirRaw
               elif pkgDirOverride.len > 0: pkgDirOverride
               else: getCurrentDir()
  let buildFilePath = pkgDir / "zpk.build"

  var m: ZpkBuildManifest
  try:
    m = loadZpkBuild(buildFilePath)
  except ZpkError as e:
    output.writeLine("✘ " & e.msg)
    return

  output.writeLine &"\n>> {m.name} {m.version} ({m.arches.join(\", \")})"
  if m.description.len > 0: output.writeLine "   " & m.description
  output.writeLine ""

  var builtAssets: seq[tuple[arch, path: string]] = @[]
  if askYesNo("ask_build_first", lang, true, input, output):
    output.writeLine t("building", lang)
    let outDir = pkgDir / "out"
    let (ok, built) = buildAll(pkgDir, m, outDir, verbose = false)
    if not ok or built.len == 0:
      output.writeLine("✘ " & t("build_failed", lang))
      return
    builtAssets = built
    output.writeLine &"✔ {built.len} archiwa .zpk zbudowane w {outDir}"
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
        output.writeLine(&"⚠ brak {candidate} -- pomijam architekturę '{arch}' przy publikacji")
    if builtAssets.len == 0:
      output.writeLine("✘ nie znaleziono żadnego wcześniej zbudowanego pliku .zpk w ./out -- " &
        "uruchom `zpk build` albo odpowiedz \"tak\" na poprzednie pytanie.")
      return

  let branch = ask("ask_branch", lang, input, output)
  var mCopy = m
  mCopy.release.branch = branch

  output.writeLine ""
  if not askYesNo("ask_confirm_pr", lang, false, input, output):
    output.writeLine t("pr_skipped", lang)
    output.writeLine t("goodbye", lang)
    return

  if findExe("gh").len == 0:
    output.writeLine t("gh_missing", lang)

  let (ok, message) = scheduleRelease(mCopy, builtAssets, verbose = false, pkgDir = pkgDir)
  output.writeLine ""
  if ok:
    output.writeLine t("pr_created", lang)
  output.writeLine message
  output.writeLine ""
  output.writeLine t("goodbye", lang)
