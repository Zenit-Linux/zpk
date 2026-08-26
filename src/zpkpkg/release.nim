import std/[os, osproc, json, strutils, strformat, times]
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

type ReleaseError* = object of CatchableError

proc sh(cmd: string, cwd: string = ""): tuple[output: string, code: int] =
  let (output, exitCode) = execCmdEx(cmd, workingDir = cwd)
  (output, exitCode)

proc buildOwnRepoEntry(m: ZpkBuildManifest, releaseAssetUrl: string): JsonNode =
  ## Wpis dodawany/aktualizowany w own-repository.json dla TEGO pakietu.
  ## `zpk` samo jest typu "binary" w tym repo (patrz README) -- ten sam
  ## kształt JSON, jaki produkuje dla SIEBIE, produkuje dla KAŻDEGO
  ## pakietu, który przez nie publikujesz.
  result = %*{
    "name": m.release.assetName,
    "type": "binary",
    "bin": releaseAssetUrl,
    "info": m.description
  }
  if m.dependsOn.len > 0:
    result["depends_on"] = %m.dependsOn

proc upsertIntoOwnRepository(repoJsonPath: string, m: ZpkBuildManifest, releaseAssetUrl: string): bool =
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

  let entry = buildOwnRepoEntry(m, releaseAssetUrl)
  var found = false
  for i in 0 ..< root["tools"].len:
    if root["tools"][i]{"name"}.getStr("") == m.release.assetName:
      if m.release.branch.len == 0:
        # Nadpisz top-level wpis (domyślny wariant), zachowując istniejące "branches".
        if root["tools"][i].hasKey("branches"):
          entry["branches"] = root["tools"][i]["branches"]
        root["tools"].elems[i] = entry
      else:
        # Dopisz/aktualizuj TYLKO branch, zachowując resztę wpisu bazowego.
        if not root["tools"][i].hasKey("branches"):
          root["tools"][i]["branches"] = newJObject()
        root["tools"][i]["branches"][m.release.branch] = %*{"bin": releaseAssetUrl}
      found = true
      break

  if not found:
    if m.release.branch.len > 0:
      var branches = newJObject()
      branches[m.release.branch] = %*{"bin": releaseAssetUrl}
      var newEntry = %*{"name": m.release.assetName, "type": "binary", "info": m.description}
      newEntry["branches"] = branches
      root["tools"].add newEntry
    else:
      root["tools"].add entry

  writeFile(repoJsonPath, root.pretty() & "\n")
  true

proc scheduleRelease*(m: ZpkBuildManifest, builtAssetPath: string, verbose: bool,
                       pkgDir: string = ".", workDir: string = ""): tuple[ok: bool, message: string] =
  let cloneDir = if workDir.len > 0: workDir else: getTempDir() / &"zpk-release-{$epochTime().int}"
  createDir(parentDir(cloneDir))

  echo &"[zpk] Klonuję {m.release.repo} ..."
  var (output, code) = sh(&"git clone --depth=1 \"{m.release.repo}\" \"{cloneDir}\"")
  if verbose: echo output
  if code != 0:
    return (false, &"nie udało się sklonować {m.release.repo}: {output}")

  let branchName = &"zpk-release-{m.name}-{m.version}"
  (output, code) = sh(&"git checkout -b {branchName}", cwd = cloneDir)
  if code != 0:
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
    return (false, &"nie udało się ustalić repo źródłowego dla release URL (uruchomiono w '{pkgDir}', czy to " &
      "katalog z 'git remote origin' skonfigurowanym?) -- ustaw release.release_repo_url w zpk.build ręcznie")

  let assetFileName = extractFilename(builtAssetPath)
  let releaseAssetUrl = &"{releaseRepo}/releases/download/v{m.version}/{assetFileName}"

  if not upsertIntoOwnRepository(repoJsonPath, m, releaseAssetUrl):
    return (false, &"aktualizacja {repoJsonPath} nie powiodła się")

  (output, code) = sh(&"git add \"{m.release.repoFile}\"", cwd = cloneDir)
  let commitMsg = &"{m.release.assetName}: dodaj/aktualizuj release {m.version}" &
    (if m.release.branch.len > 0: &" (branch: {m.release.branch})" else: "")
  (output, code) = sh(&"git -c user.email=zpk@zenit-linux.local -c user.name=\"zpk release bot\" " &
    &"commit -m \"{commitMsg}\"", cwd = cloneDir)
  if code != 0:
    return (false, &"commit nie powiódł się (może brak zmian?): {output}")

  if findExe("gh").len == 0:
    return (true, &"Commit gotowy na lokalnej gałęzi '{branchName}' w {cloneDir}, ALE 'gh' (GitHub CLI) " &
      &"nie jest zainstalowane -- push i PR musisz zrobić ręcznie:\n" &
      &"  cd \"{cloneDir}\" && git push -u origin {branchName}\n" &
      &"  gh pr create --fill   (albo utwórz PR ręcznie na GitHubie)")

  (output, code) = sh(&"git push -u origin {branchName}", cwd = cloneDir)
  if code != 0:
    return (false, &"push gałęzi {branchName} nie powiódł się: {output}")

  (output, code) = sh(&"gh pr create --title \"{commitMsg}\" --body \"Automatyczny PR z 'zpk schedule-release' " &
    &"dla pakietu {m.name} {m.version}.\" --fill", cwd = cloneDir)
  if code != 0:
    return (true, &"Push gałęzi '{branchName}' udany, ale 'gh pr create' nie powiodło się: {output}\n" &
      &"Utwórz PR ręcznie z gałęzi '{branchName}' w {m.release.repo}.")

  (true, &"Pull request utworzony: {output.strip()}")
