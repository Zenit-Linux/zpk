import std/[os, strutils, strformat]
import ./manifest
import ./types

## `zpk bump-version` -- WCZEŚNIEJ nie istniało żadne wsparcie dla
## podnoszenia wersji: trzeba było ręcznie edytować `package.version` w
## `zpk.build`, z ryzykiem literówki/niepoprawnego semver.
##
## Zamierzenie: podmienia WYŁĄCZNIE wartość `version` w pliku, bez
## przepuszczania całego pliku przez parser HCL i ponownego zapisu (co
## zniszczyłoby komentarze i formatowanie operatora) -- operuje na
## surowym tekście, liniowo, i modyfikuje TYLKO pierwszą linię, której
## klucz (przed '=') to dokładnie "version".

type BumpKind* = enum
  bkMajor, bkMinor, bkPatch

proc parseSemverParts(version: string): tuple[major, minor, patch: int, pre: string] =
  ## Zakłada, że `version` już przeszło `isValidSemver` (wywołujący
  ## odpowiada za walidację) -- stąd `parseInt` bez try/except tutaj.
  let dashIdx = version.find('-')
  let core = if dashIdx >= 0: version[0 ..< dashIdx] else: version
  let pre = if dashIdx >= 0: version[dashIdx+1 .. ^1] else: ""
  let parts = core.split('.')
  (parseInt(parts[0]), parseInt(parts[1]), parseInt(parts[2]), pre)

proc bumpedVersion*(current: string, kind: BumpKind): string =
  ## Podnosi wersję wg semver: major zeruje minor+patch, minor zeruje
  ## patch, patch tylko inkrementuje. Sufiks "-prerelease" (jeśli był)
  ## jest ODRZUCANY przy podniesieniu -- podniesienie wersji z
  ## "1.2.3-rc1" oznacza wyjście z fazy prerelease, nie jej kontynuację.
  var (maj, minr, pat, _) = parseSemverParts(current)
  case kind
  of bkMajor:
    inc maj
    minr = 0
    pat = 0
  of bkMinor:
    inc minr
    pat = 0
  of bkPatch:
    inc pat
  &"{maj}.{minr}.{pat}"

proc bumpVersionInFile*(path, newVersion: string): tuple[ok: bool, oldVersion, newVersion: string, message: string] =
  ## Podmienia wartość `version = "..."` w `path` na `newVersion`,
  ## zachowując resztę pliku (komentarze, formatowanie, kolejność)
  ## bez zmian. Nie waliduje `newVersion` -- to obowiązek wywołującego
  ## (patrz `isValidSemver` w manifest.nim).
  if not fileExists(path):
    return (false, "", "", &"nie znaleziono {path}")

  var m: ZpkBuildManifest
  try:
    m = loadZpkBuild(path)
  except ZpkError as e:
    return (false, "", "", e.msg)
  let oldVersion = m.version

  var lines = readFile(path).splitLines()
  var replaced = false
  for i in 0 ..< lines.len:
    if replaced: break
    let eqIdx = lines[i].find('=')
    if eqIdx < 0: continue
    let keyPart = lines[i][0 ..< eqIdx].strip()
    if keyPart == "version":
      let beforeEq = lines[i][0 ..< eqIdx]
      lines[i] = beforeEq & "= \"" & newVersion & "\""
      replaced = true

  if not replaced:
    return (false, oldVersion, "", &"nie znaleziono linii 'version = ...' w {path} -- edytuj ręcznie")

  writeFile(path, lines.join("\n"))
  (true, oldVersion, newVersion, &"{oldVersion} -> {newVersion}")
