import std/[os, osproc, strutils]

## Weryfikacja `package.depends_on` -- WCZEŚNIEJ pole było CZYSTO
## DEKLARATYWNE: `zpk` zapisywało je do manifestu, ale nigdy nie
## sprawdzało, czy zależności faktycznie ISTNIEJĄ w systemie, w którym
## się buduje/instaluje. Pakiet mógł się "zbudować" (recipe akurat nie
## potrzebowało zależności W CZASIE BUDOWANIA), a i tak nie działać po
## instalacji, bo zależność uruchomieniowa nigdy nie została zainstalowana.
##
## UCZCIWIE: to jest HEURYSTYKA, nie twarda gwarancja integracji z zpm.
## Dwa poziomy sprawdzenia, w kolejności:
##   1. Jeśli `zpm` jest w PATH: `zpm list --installed`, dopasowanie
##      nazwy zależności jako CAŁEGO SŁOWA w wyjściu.
##   2. Jeśli `zpm` NIE jest w PATH: fallback -- sprawdza, czy istnieje
##      binarka o TEJ SAMEJ nazwie w PATH (`findExe`). To słabsze
##      przybliżenie (pakiet != binarka o identycznej nazwie), ale
##      lepsze niż zero informacji.
## Jeśli `zpm list --installed` zwróci błąd (kod != 0), status to
## `dsUnknown` (nie `dsMissing`) -- nie chcemy fałszywie krzyczeć "BRAK",
## kiedy tak naprawdę nie umiemy sprawdzić.

type DependencyStatus* = enum
  dsInstalled, dsMissing, dsUnknown

proc statusLabel*(status: DependencyStatus): string =
  case status
  of dsInstalled: "zainstalowana"
  of dsMissing: "BRAK"
  of dsUnknown: "nie można sprawdzić"

proc zpmAvailable*(): bool =
  findExe("zpm").len > 0

proc checkDependencies*(dependsOn: seq[string]): seq[tuple[name: string, status: DependencyStatus]] =
  ## Zwraca status KAŻDEJ zależności z `dependsOn`, w tej samej
  ## kolejności. Nigdy nie rzuca -- błąd `zpm` też jest tylko statusem
  ## `dsUnknown` dla wszystkich zależności naraz.
  result = @[]
  if dependsOn.len == 0: return
  if zpmAvailable():
    let (output, code) = execCmdEx("zpm list --installed")
    if code != 0:
      for dep in dependsOn: result.add (dep, dsUnknown)
      return
    let installedWords = output.splitWhitespace()
    for dep in dependsOn:
      result.add (dep, (if dep in installedWords: dsInstalled else: dsMissing))
  else:
    # Fallback bez zpm: czy istnieje binarka o tej samej nazwie w PATH.
    for dep in dependsOn:
      result.add (dep, (if findExe(dep).len > 0: dsInstalled else: dsMissing))
