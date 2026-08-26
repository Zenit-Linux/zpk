import std/[times]

## Schemat `ZpkManifest`/`ZpkFileEntry` MUSI zostać zgodny 1:1 z tym, co
## zpm (src/zpmpkg/zpk.nim) umie zainstalować -- `zpk` to OFICJALNY
## builder pakietów .zpk dla zpm, nie osobny, konkurencyjny format. Jeśli
## zmienia się jedno, drugie wymaga tej samej zmiany (i podniesienia
## `ManifestSchemaVersion` po obu stronach).

const ManifestSchemaVersion* = 1
const ManifestFileName* = "manifest.json"

type
  ZpkFileEntry* = object
    path*: string
    sha256*: string

  ZpkManifest* = object
    name*: string
    version*: string
    arch*: string
    dependsOn*: seq[string]
    sha256*: string
    description*: string
    buildRecipe*: string
    builtAt*: string
    files*: seq[ZpkFileEntry]

  # ---- zpk.build (HCL) -- metadane budowania, OSOBNE od manifestu -----
  ZpkReleaseTarget* = object
    ## blok `release { }` w zpk.build -- dokąd i jak `zpk schedule-release`
    ## / `zpk tutorial-release` mają opublikować gotowy pakiet.
    repo*: string           ## repo z own-repository.json, domyślnie
                             ## https://github.com/Zenit-Linux/own-repository
    repoFile*: string       ## ścieżka pliku w repo, domyślnie "repo/own-repository.json"
    branch*: string         ## branch own-repository (stable/rolling/semi-rolling/testing/...)
                             ## -- pusty = wpis top-level (bez "branches")
    assetName*: string      ## nazwa narzędzia w own-repository.json (domyślnie = package.name)
    releaseRepoUrl*: string ## repo GitHub, do którego trafia zbudowana binarka jako Release Asset
                             ## (domyślnie: to samo repo co source recipe, jeśli wykrywalne przez git)

  ZpkBuildManifest* = object
    ## Sparsowana zawartość `zpk.build` -- GŁÓWNY plik informacyjny
    ## pakietu (patrz zpkpkg/manifest.nim).
    name*: string
    version*: string
    arches*: seq[string]     ## domyślnie @["x86_64"]
    description*: string
    dependsOn*: seq[string]
    recipeFile*: string       ## domyślnie "recipe.janet"
    recipeLang*: string       ## domyślnie "janet"
    release*: ZpkReleaseTarget
    rawPath*: string          ## ścieżka do zpk.build, z którego to pochodzi (do komunikatów błędów)

proc nowIso8601*(): string =
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
