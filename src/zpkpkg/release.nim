import std/[os, osproc, json, strutils, strformat, times, sequtils]
import ./types

## `zpk schedule-release` -- "teleportuje do: pull requesta do pliku
## https://github.com/Zenit-Linux/own-repository/blob/main/repo/own-repository.json"
## (cytat z wymagań). Realizacja: klonuje/aktualizuje lokalną kopię repo
## `own-repository` (albo używa już sklonowanej, jeśli operator ją ma),
## dopisuje/aktualizuje wpis TEGO pakietu w `repo/own-repository.json`
## (root-level dla domyślnego brancha, albo w polu "branches" -- patrz
## `own-repository.json` schema_version 2 w zpm), commituje na nowej
## gałęzi, pushuje i tworzy Pull Request przez `gh` (GitHub CLI) --
## jeśli `gh` nie jest zainstalowane, zatrzymuje się PO commicie na
## lokalnej gałęzi i podaje dokładną instrukcję, co zrobić ręcznie.
##
## UCZCIWIE: to NIE jest integracja z GitHub API przez token (żadnych
## sekretów w kodzie zpk) -- deleguje autentykację do już-zalogowanego
## `gh` (standardowe, udokumentowane narzędzie GitHub do dokładnie tego
## zastosowania), więc `zpk` samo nigdy nie dotyka poświadczeń operatora.
##
## NOWOŚĆ: wcześniej `zpk` wyliczało URL assetu Release
## (`.../releases/download/vX.Y.Z/<plik>`) i wpisywało go do
## own-repository.json, ZAKŁADAJĄC że coś INNEGO (osobny workflow CI)
## faktycznie utworzy ten Release i wgra plik -- jeśli nikt tego nie
## zrobił, wpis wskazywał donikąd. Teraz, gdy `gh` jest dostępne,
## `zpk` samo tworzy/aktualizuje Release i wgrywa asset (patrz
## `ensureReleaseAsset` niżej), więc URL w PR faktycznie działa od razu.

type ReleaseError* = object of CatchableError

proc sh(cmd: string, cwd: string = ""): tuple[output: string, code: int] =
  let (output, exitCode) = execCmdEx(cmd, workingDir = cwd)
  (output, exitCode)

proc buildOwnRepoEntry(assetName, description: string, dependsOn: seq[string],
                        binUrls: seq[tuple[arch, url: string]]): JsonNode =
  ## Wpis dodawany/aktualizowany w own-repository.json dla TEGO pakietu.
  ## `zpk` samo jest typu "binary" w tym repo (patrz README) -- ten sam
  ## kształt JSON, jaki produkuje dla SIEBIE, produkuje dla KAŻDEGO
  ## pakietu, który przez nie publikujesz.
  ##
  ## Jeśli zbudowano TYLKO JEDNĄ architekturę, "bin" to zwykły string
  ## (kompatybilne wstecz z dotychczasowym schematem). Jeśli zbudowano
  ## WIĘCEJ NIŻ JEDNĄ (np. `zpk build --release` dla x86_64+aarch64),
  ## "bin" staje się obiektem {arch: url, ...} -- wcześniej
  ## `schedule-release` publikowało URL WYŁĄCZNIE pierwszej zbudowanej
  ## architektury, więc reszta była budowana, ale nigdy nie trafiała
  ## do own-repository.json.
  result = %*{
    "name": assetName,
    "type": "binary",
    "info": description
  }
  if binUrls.len == 1:
    result["bin"] = %binUrls[0].url
  else:
    var binObj = newJObject()
    for (arch, url) in binUrls:
      binObj[arch] = %url
    result["bin"] = binObj
  if dependsOn.len > 0:
    result["depends_on"] = %dependsOn

proc upsertIntoOwnRepository*(repoJsonPath, assetName, description: string, dependsOn: seq[string],
                               branch: string, binUrls: seq[tuple[arch, url: string]]): bool =
  ## Wyodrębnione (i wyeksportowane) z `scheduleRelease`, żeby dało się
  ## to testować bez klonowania prawdziwego repo Git -- wcześniej cała
  ## logika scalania JSON-a była wewnętrzną `proc` bez żadnego testu.
  var root: JsonNode
  if fileExists(repoJsonPath):
    try:
      root = parseJson(readFile(repoJsonPath))
    except CatchableError as e:
      stderr.writeLine(&"[zpk] ✘ {repoJsonPath} nie jest poprawnym JSON-em: {e.msg}")
      return false
  else:
    root = %*{"schema_version": 2, "tools": []}

  if not root.hasKey("tools") or root["tools"].kind != JArray:
    root["tools"] = newJArray()

  let entry = buildOwnRepoEntry(assetName, description, dependsOn, binUrls)
  var found = false
  for i in 0 ..< root["tools"].len:
    if root["tools"][i]{"name"}.getStr("") == assetName:
      if branch.len == 0:
        # Nadpisz top-level wpis (domyślny wariant), zachowując istniejące "branches".
        if root["tools"][i].hasKey("branches"):
          entry["branches"] = root["tools"][i]["branches"]
        root["tools"].elems[i] = entry
      else:
        # Dopisz/aktualizuj TYLKO branch, zachowując resztę wpisu bazowego.
        if not root["tools"][i].hasKey("branches"):
          root["tools"][i]["branches"] = newJObject()
        root["tools"][i]["branches"][branch] = %*{"bin": entry["bin"]}
      found = true
      break

  if not found:
    if branch.len > 0:
      var branches = newJObject()
      branches[branch] = %*{"bin": entry["bin"]}
      var newEntry = %*{"name": assetName, "type": "binary", "info": description}
      newEntry["branches"] = branches
      root["tools"].add newEntry
    else:
      root["tools"].add entry

  writeFile(repoJsonPath, root.pretty() & "\n")
  true

proc ensureReleaseAsset(releaseRepo, tag, assetPath: string, verbose: bool): tuple[ok: bool, message: string] =
  ## Tworzy (jeśli brakuje) GitHub Release `tag` w `releaseRepo` i wgrywa
  ## `assetPath` -- wymaga `gh`. Wcześniej `zpk` NIGDY tego nie robiło:
  ## tylko zakładało istnienie Release'u pod przewidywalnym URL-em.
  if findExe("gh").len == 0:
    return (false, "'gh' niedostępne -- nie mogę automatycznie utworzyć/zaktualizować " &
      &"GitHub Release ani wgrać assetu. Zrób to ręcznie: `gh release create {tag} " &
      quoteShell(assetPath) & &" --repo {releaseRepo}` (albo odpowiednik przez UI GitHuba).")
  let repoSlug = releaseRepo.replace("https://github.com/", "")
  let (_, viewCode) = sh(&"gh release view {quoteShell(tag)} --repo {quoteShell(repoSlug)}")
  var cmd: string
  if viewCode == 0:
    cmd = &"gh release upload {quoteShell(tag)} {quoteShell(assetPath)} --repo {quoteShell(repoSlug)} --clobber"
  else:
    cmd = &"gh release create {quoteShell(tag)} {quoteShell(assetPath)} --repo {quoteShell(repoSlug)} " &
      &"--title {quoteShell(tag)} --generate-notes"
  if verbose: echo &"[zpk] $ {cmd}"
  let (output, code) = sh(cmd)
  if code != 0:
    return (false, &"nie udało się utworzyć/zaktualizować Release '{tag}' w {releaseRepo}: {output}")
  (true, &"Release '{tag}' w {releaseRepo}: asset {extractFilename(assetPath)} wgrany.")

proc scheduleRelease*(m: ZpkBuildManifest, builtAssets: seq[tuple[arch, path: string]], verbose: bool,
                       pkgDir: string = ".", workDir: string = "", dryRun: bool = false,
                       skipReleaseUpload: bool = false): tuple[ok: bool, message: string] =
  ## `builtAssets`: WSZYSTKIE zbudowane pliki .zpk (jedna para na
  ## architekturę), nie tylko pierwszy -- patrz `buildOwnRepoEntry`.
  if builtAssets.len == 0:
    return (false, "brak zbudowanych assetów do opublikowania")
  for (arch, path) in builtAssets:
    if not fileExists(path):
      return (false, &"zadeklarowany asset dla architektury '{arch}' nie istnieje na dysku: {path}")

  let cloneDir = if workDir.len > 0: workDir else: getTempDir() / &"zpk-release-{$epochTime().int}"
  createDir(parentDir(cloneDir))
  # Katalog klonu repo own-repository jest sprzątany PO ZAKOŃCZENIU, chyba
  # że zwracamy instrukcję "dokończ ręcznie" (wtedy operator go potrzebuje)
  # albo `dryRun` (wtedy zostawiamy do wglądu celowo). Wcześniej ten
  # katalog NIGDY nie był usuwany -- każde `schedule-release` zostawiało
  # śmieci w /tmp.
  var keepCloneDir = dryRun

  echo &"[zpk] Klonuję {m.release.repo} ..."
  var (output, code) = sh(&"git clone --depth=1 {quoteShell(m.release.repo)} {quoteShell(cloneDir)}")
  if verbose: echo output
  if code != 0:
    if dirExists(cloneDir): removeDir(cloneDir)  # git clone może zostawić pusty/częściowy katalog
    return (false, &"nie udało się sklonować {m.release.repo}: {output}")

  let branchName = &"zpk-release-{m.name}-{m.version}"
  (output, code) = sh(&"git checkout -b {quoteShell(branchName)}", cwd = cloneDir)
  if code != 0:
    removeDir(cloneDir)
    return (false, &"nie udało się utworzyć gałęzi {branchName}: {output}")

  let repoJsonPath = cloneDir / m.release.repoFile
  createDir(parentDir(repoJsonPath))

  # URL assetu wydania -- zakłada standardowy layout GitHub Releases
  # (patrz `zpk build --release` + workflow CI): jeśli m.release.releaseRepoUrl
  # jest ustawione, użyj go; inaczej zbuduj z bieżącego repo (wykryte przez
  # `git remote get-url origin` w katalogu pakietu, NIE w cloneDir).
  var releaseRepo = m.release.releaseRepoUrl
  if releaseRepo.len == 0:
    let (originUrl, originCode) = sh("git remote get-url origin", cwd = pkgDir)
    if originCode == 0:
      releaseRepo = originUrl.strip().replace(".git", "").replace("git@github.com:", "https://github.com/")
  if releaseRepo.len == 0:
    removeDir(cloneDir)
    return (false, &"nie udało się ustalić repo źródłowego dla release URL (uruchomiono w '{pkgDir}', czy to " &
      "katalog z 'git remote origin' skonfigurowanym?) -- ustaw release.release_repo_url w zpk.build ręcznie")

  let tag = &"v{m.version}"
  var binUrls: seq[tuple[arch, url: string]] = @[]
  for (arch, path) in builtAssets:
    let assetFileName = extractFilename(path)
    binUrls.add (arch, &"{releaseRepo}/releases/download/{tag}/{assetFileName}")

  if not upsertIntoOwnRepository(repoJsonPath, m.release.assetName, m.description, m.dependsOn,
                                  m.release.branch, binUrls):
    removeDir(cloneDir)
    return (false, &"aktualizacja {repoJsonPath} nie powiodła się")

  if dryRun:
    return (true, &"[dry-run] Nic nie zostało wypchnięte ani opublikowane. Podgląd zmian w " &
      &"{repoJsonPath} (katalog roboczy zachowany: {cloneDir}). URL(e) assetu: " &
      binUrls.mapIt(&"{it.arch}={it.url}").join(", "))

  (output, code) = sh(&"git add {quoteShell(m.release.repoFile)}", cwd = cloneDir)
  let commitMsg = &"{m.release.assetName}: dodaj/aktualizuj release {m.version}" &
    (if m.release.branch.len > 0: &" (branch: {m.release.branch})" else: "")
  (output, code) = sh(&"git -c user.email=zpk@zenit-linux.local -c user.name=" & quoteShell("zpk release bot") &
    " commit -m " & quoteShell(commitMsg), cwd = cloneDir)
  if code != 0:
    removeDir(cloneDir)
    return (false, &"commit nie powiódł się (może brak zmian?): {output}")

  # Wgraj same pliki .zpk jako assety GitHub Release, ZANIM otworzymy PR,
  # żeby URL-e wpisane do own-repository.json od razu działały (o ile
  # `gh` jest dostępne -- inaczej ostrzegamy, ale kontynuujemy z PR-em,
  # bo wpis w own-repository i tak trzeba zreview'ować).
  var uploadWarnings: seq[string] = @[]
  if not skipReleaseUpload:
    for (_, path) in builtAssets:
      let (uploadOk, uploadMsg) = ensureReleaseAsset(releaseRepo, tag, path, verbose)
      if not uploadOk: uploadWarnings.add uploadMsg

  if findExe("gh").len == 0:
    keepCloneDir = true
    return (true, &"Commit gotowy na lokalnej gałęzi '{branchName}' w {cloneDir}, ALE 'gh' (GitHub CLI) " &
      &"nie jest zainstalowane -- push, upload assetu i PR musisz zrobić ręcznie:\n" &
      &"  cd \"{cloneDir}\" && git push -u origin {branchName}\n" &
      &"  gh pr create --fill   (albo utwórz PR ręcznie na GitHubie)\n" &
      &"  gh release create {tag} <plik.zpk> --repo {releaseRepo.replace(\"https://github.com/\", \"\")}")

  (output, code) = sh(&"git push -u origin {quoteShell(branchName)}", cwd = cloneDir)
  if code != 0:
    keepCloneDir = true
    return (false, &"push gałęzi {branchName} nie powiódł się: {output}")

  (output, code) = sh(&"gh pr create --title {quoteShell(commitMsg)} --body " &
    quoteShell(&"Automatyczny PR z 'zpk schedule-release' dla pakietu {m.name} {m.version}.") &
    " --fill", cwd = cloneDir)

  if not keepCloneDir:
    removeDir(cloneDir)

  let warnSuffix = if uploadWarnings.len > 0: "\n⚠ " & uploadWarnings.join("\n⚠ ") else: ""

  if code != 0:
    # Push się udał, więc gałąź i JSON są bezpieczne na zdalnym repo --
    # tylko samo utworzenie PR przez `gh` zawiodło (np. już istnieje PR
    # z tej gałęzi). Traktujemy to jak wcześniej: ok=true, bo praca nie
    # przepadła, operator dokończy ręcznie.
    return (true, &"Push gałęzi '{branchName}' udany, ale 'gh pr create' nie powiodło się: {output}\n" &
      &"Utwórz PR ręcznie z gałęzi '{branchName}' w {m.release.repo}." & warnSuffix)

  (true, &"Pull request utworzony: {output.strip()}" & warnSuffix)
