import std/[os, strutils, strformat]
import ./hcl
import ./types

type ZpkError* = object of CatchableError

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
  if not fileExists(path):
    raise newException(ZpkError, &"nie znaleziono {path} -- uruchom `zpk init` w katalogu pakietu")

  var root: HclBlock
  try:
    root = parseHcl(readFile(path))
  except HclParseError as e:
    raise newException(ZpkError, &"{path}: {e.msg}")

  let pkgBlk = root.findBlock("package")
  if pkgBlk == nil:
    raise newException(ZpkError, &"{path}: brak wymaganego bloku 'package {{ }}'")

  let name = pkgBlk.getStr("name")
  if name.len == 0:
    raise newException(ZpkError, &"{path}: package.name jest wymagane")
  let version = pkgBlk.getStr("version")
  if version.len == 0:
    raise newException(ZpkError, &"{path}: package.version jest wymagane")

  var arches = pkgBlk.getList("arch")
  if arches.len == 0: arches = @["x86_64"]

  let recipeBlk = root.findBlock("recipe")
  let recipeFile = if recipeBlk != nil: recipeBlk.getStr("file", "recipe.janet") else: "recipe.janet"
  let recipeLang = if recipeBlk != nil: recipeBlk.getStr("lang", "janet") else: "janet"

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
    release: release, rawPath: path
  )
