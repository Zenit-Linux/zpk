import std/[os, strutils, strformat, sets, tables]
import ./hcl
import ./types

type ZpkError* = object of CatchableError

const namePattern = {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}

proc isValidPackageName(name: string): bool =
  ## Konwencja Zenit Linux: nazwy pakietów/narzędzi w own-repository.json
  ## są używane jako fragmenty nazw plików (`<name>-<version>-<arch>.zpk`)
  ## i jako klucze URL -- spacje, '/', cudzysłowy itd. by je łamały.
  if name.len == 0: return false
  for c in name:
    if c notin namePattern: return false
  true

proc isValidSemver*(version: string): bool =
  ## Luźna walidacja semver: MAJOR.MINOR.PATCH z opcjonalnym
  ## sufiksem "-prerelease" (np. "1.2.3-rc1") -- wystarczające dla
  ## `zpk`, które i tak tylko wstawia `version` do nazw plików i URL-i
  ## Release, nie robi porównań wersji.
  let core = version.split('-', maxsplit = 1)[0]
  let parts = core.split('.')
  if parts.len != 3: return false
  for p in parts:
    if p.len == 0: return false
    for c in p:
      if not c.isDigit: return false
  true

proc validateBlockShape(root: HclBlock, path: string) =
  ## Wykrywa zduplikowane bloki `package{}`/`recipe{}`/`release{}` --
  ## `findBlock` (używane niżej) po cichu bierze tylko PIERWSZY, więc
  ## bez tej kontroli literówka typu wklejenie drugiego `package{}`
  ## kończyła się cichym zignorowaniem drugiego bloku zamiast błędu.
  for blockName in ["package", "recipe", "release"]:
    let matches = root.findAllBlocks(blockName)
    if matches.len > 1:
      raise newException(ZpkError,
        &"{path}: znaleziono {matches.len} bloków '{blockName} {{ }}' -- dozwolony jest tylko jeden")

proc loadZpkBuild*(path: string): ZpkBuildManifest =
  ## Parsuje `zpk.build` -- GŁÓWNY plik informacyjny pakietu, jak
  ## zapowiedziano: "info bedzie w zpk.build". Format HCL, trzy bloki:
  ##
  ##   package {
  ##     name        = "hello-world"
  ##     version     = "1.0.0"
  ##     arch        = ["x86_64", "aarch64"]
  ##     description = "Przykładowy pakiet .zpk"
  ##     depends_on  = ["glibc"]
  ##   }
  ##
  ##   recipe {
  ##     file = "recipe.janet"   # domyślnie
  ##     lang = "janet"          # domyślnie
  ##   }
  ##
  ##   release {
  ##     repo        = "https://github.com/Zenit-Linux/own-repository"
  ##     repo_file   = "repo/own-repository.json"
  ##     branch      = "stable"
  ##     asset_name  = "hello-world"
  ##   }
  ##
  ## Waliduje TYLKO kształt/typy danych (parsowalny HCL + wymagane pola +
  ## semver + dozwolone znaki w nazwie + brak duplikatów arch/bloków).
  ## NIE sprawdza istnienia pliku recipe ani dostępności interpretera w
  ## PATH -- to zależy od `pkgDir`, którego ta funkcja nie zna (patrz
  ## `validateZpkBuildFull` niżej, używane przez `zpk validate`).
  if not fileExists(path):
    raise newException(ZpkError, &"nie znaleziono {path} -- uruchom `zpk init` w katalogu pakietu")

  var root: HclBlock
  try:
    root = parseHcl(readFile(path))
  except HclParseError as e:
    raise newException(ZpkError, &"{path}: {e.msg}")

  validateBlockShape(root, path)

  let pkgBlk = root.findBlock("package")
  if pkgBlk == nil:
    raise newException(ZpkError, &"{path}: brak wymaganego bloku 'package {{ }}'")

  let name = pkgBlk.getStr("name")
  if name.len == 0:
    raise newException(ZpkError, &"{path}: package.name jest wymagane")
  if not isValidPackageName(name):
    raise newException(ZpkError,
      &"{path}: package.name '{name}' zawiera niedozwolone znaki -- dozwolone: litery, cyfry, '-', '_', '.'")

  let version = pkgBlk.getStr("version")
  if version.len == 0:
    raise newException(ZpkError, &"{path}: package.version jest wymagane")
  if not isValidSemver(version):
    raise newException(ZpkError,
      &"{path}: package.version '{version}' nie wygląda na semver (oczekiwano MAJOR.MINOR.PATCH, np. \"1.2.3\")")

  var arches = pkgBlk.getList("arch")
  if arches.len == 0: arches = @["x86_64"]
  block checkDupArches:
    var seen = initHashSet[string]()
    for a in arches:
      if a in seen:
        raise newException(ZpkError, &"{path}: architektura '{a}' powtórzona więcej niż raz w package.arch")
      seen.incl a
  for a in arches:
    if a notin KnownArches:
      stderr.writeLine(&"[zpk] ⚠ {path}: nieznana architektura '{a}' (znane: {KnownArches.join(\", \")}) -- literówka?")

  let recipeBlk = root.findBlock("recipe")
  let recipeFile = if recipeBlk != nil: recipeBlk.getStr("file", "recipe.janet") else: "recipe.janet"
  let recipeLang = if recipeBlk != nil: recipeBlk.getStr("lang", "janet") else: "janet"

  # `toolchains { arch = "prefiks-" }` -- OPCJONALNY blok, patrz
  # types.nim (pole ZpkBuildManifest.toolchains) i builder.nim (jak
  # prefiks jest używany do ustawienia CC/CXX/AR/STRIP dla recipe przy
  # cross-budowaniu). Klucze to nazwy dowolnych architektur (nie tylko
  # z KnownArches -- świadomie, żeby nie blokować nietypowych targetów),
  # wartości MUSZĄ być stringami (inne typy są po cichu pomijane, żeby
  # literówka w typie nie wywalała całego builda -- `zpk validate`
  # i tak by tego nie złapał precyzyjniej niż ostrzeżeniem).
  var toolchains = initTable[string, string]()
  let toolchainsBlk = root.findBlock("toolchains")
  if toolchainsBlk != nil:
    for key, val in toolchainsBlk.attrs:
      if val.kind == hvString:
        toolchains[key] = val.strVal

  var release = ZpkReleaseTarget(
    repo: "https://github.com/Zenit-Linux/own-repository",
    repoFile: "repo/own-repository.json",
    branch: "",
    assetName: name,
    releaseRepoUrl: ""
  )
  let relBlk = root.findBlock("release")
  if relBlk != nil:
    release.repo = relBlk.getStr("repo", release.repo)
    release.repoFile = relBlk.getStr("repo_file", release.repoFile)
    release.branch = relBlk.getStr("branch", release.branch)
    release.assetName = relBlk.getStr("asset_name", release.assetName)
    release.releaseRepoUrl = relBlk.getStr("release_repo_url", release.releaseRepoUrl)

  ZpkBuildManifest(
    name: name, version: version, arches: arches,
    description: pkgBlk.getStr("description", ""),
    dependsOn: pkgBlk.getList("depends_on"),
    recipeFile: recipeFile, recipeLang: recipeLang,
    release: release, rawPath: path, toolchains: toolchains
  )

proc validateZpkBuildFull*(m: ZpkBuildManifest, pkgDir: string): seq[string] =
  ## Walidacja "pełna", używana przez `zpk validate` -- oprócz tego, co
  ## sprawdza już `loadZpkBuild` (składnia/typy), dotyka systemu plików:
  ## czy plik recipe istnieje względem katalogu pakietu i czy interpreter
  ## wskazany w `recipe.lang` jest w PATH. Wcześniej `zpk validate`
  ## przechodziło "✔ OK" nawet gdy `recipe.janet` nie istniał albo
  ## interpreter nigdy nie zostanie znaleziony -- błąd wychodził dopiero
  ## przy `zpk build`, na etapie faktycznego budowania.
  ##
  ## Zwraca listę OSTRZEŻEŃ (nie rzuca) -- wywołujący decyduje, czy
  ## traktować je jako twardy błąd.
  result = @[]
  let recipePath = pkgDir / m.recipeFile
  if not fileExists(recipePath):
    result.add &"plik recipe '{recipePath}' nie istnieje"
  let interp = if m.recipeLang.len == 0: "janet" else: m.recipeLang
  if findExe(interp).len == 0:
    result.add &"interpreter '{interp}' (recipe.lang) nie jest dostępny w PATH"
  if m.release.repo.len > 0 and not (m.release.repo.startsWith("https://") or m.release.repo.startsWith("git@")):
    result.add &"release.repo '{m.release.repo}' nie wygląda na URL git (https://... albo git@...)"
