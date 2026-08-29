import std/[strutils, tables, strformat]

type
  HclValueKind* = enum
    hvString, hvInt, hvFloat, hvBool, hvList

  HclValue* = object
    case kind*: HclValueKind
    of hvString: strVal*: string
    of hvInt: intVal*: int
    of hvFloat: floatVal*: float
    of hvBool: boolVal*: bool
    of hvList: listVal*: seq[string]

  HclBlock* = ref object
    name*: string
    attrs*: Table[string, HclValue]
    children*: seq[HclBlock]

  HclParseError* = object of CatchableError
    ## Rzucany z NUMEREM LINII w komunikacie -- celowo zamiast po cichu
    ## mis-parsować (np. traktować niedomknięty blok jako pusty string),
    ## bo cichy błąd konfiguracji w produkcyjnym `/etc/zpm/config.hcl`
    ## jest dużo gorszy niż `quit(1)` z jasnym miejscem problemu.

proc newHclBlock*(name: string): HclBlock =
  HclBlock(name: name, attrs: initTable[string, HclValue](), children: @[])

proc unescapeHclString(inner: string, lineNo: int): string =
  ## Obsługuje `\"` i `\\` wewnątrz stringów HCL (np. ścieżki Windows albo
  ## URL-e z escapowanym cudzysłowem) -- bez tego `"a \" b"` było po
  ## prostu ucinane na pierwszym escapowanym cudzysłowie bez ostrzeżenia.
  result = newStringOfCap(inner.len)
  var i = 0
  while i < inner.len:
    if inner[i] == '\\' and i + 1 < inner.len and inner[i+1] in {'"', '\\'}:
      result.add inner[i+1]
      i += 2
    elif inner[i] == '\\' and i + 1 >= inner.len:
      raise newException(HclParseError, &"linia {lineNo}: string urwany na znaku ucieczki '\\' na końcu linii")
    else:
      result.add inner[i]
      inc i

proc readQuotedString(v: string, startIdx: int, lineNo: int): tuple[value: string, nextIdx: int] =
  ## Czyta string w cudzysłowie zaczynający się w `v[startIdx]` (który musi
  ## być '"'). Zwraca ODESCAPOWANĄ zawartość oraz indeks TUŻ ZA zamykającym
  ## cudzysłowem. Współdzielone przez parseValue (pojedyncza wartość) i
  ## splitHclList (elementy listy) -- wcześniej lista dzieliła po samym
  ## przecinku, więc element `"a,b"` (przecinek WEWNĄTRZ cudzysłowu) się
  ## rozjeżdżał na dwa elementy; teraz oba miejsca parsują stringi tak samo.
  var j = startIdx + 1
  while j < v.len:
    if v[j] == '"' and v[j-1] != '\\':
      return (unescapeHclString(v[startIdx+1 ..< j], lineNo), j + 1)
    inc j
  raise newException(HclParseError, &"linia {lineNo}: niedomknięty string (brakujący końcowy '\"')")

proc looksNumeric(v: string): bool =
  if v.len == 0: return false
  var i = 0
  if v[0] == '-' or v[0] == '+': i = 1
  if i >= v.len: return false
  var sawDigit = false
  while i < v.len:
    if v[i].isDigit: sawDigit = true
    elif v[i] == '.': discard
    else: return false
    inc i
  sawDigit

proc splitHclList(inner: string, lineNo: int): seq[string] =
  ## Dzieli zawartość listy `["a", "b, c", "d"]` (bez nawiasów kwadratowych)
  ## na elementy, respektując przecinki WEWNĄTRZ cudzysłowów -- naiwny
  ## `inner.split(',')` (wcześniejsza implementacja) łamał listy typu
  ## `["a,b", "c"]` na trzy elementy zamiast dwóch.
  result = @[]
  var i = 0
  while i < inner.len:
    while i < inner.len and inner[i] in {' ', '\t'}: inc i
    if i >= inner.len: break
    if inner[i] == '"':
      let (s, nextIdx) = readQuotedString(inner, i, lineNo)
      result.add s
      i = nextIdx
    else:
      # element niecudzysłowiony (np. liczba) -- czytaj do przecinka
      var j = i
      while j < inner.len and inner[j] != ',': inc j
      let piece = inner[i ..< j].strip()
      if piece.len > 0: result.add piece
      i = j
    while i < inner.len and inner[i] in {' ', '\t'}: inc i
    if i < inner.len and inner[i] == ',':
      inc i
    elif i < inner.len:
      raise newException(HclParseError, &"linia {lineNo}: oczekiwano ',' albo ']' w liście, znaleziono '{inner[i]}'")

proc parseValue(raw: string, lineNo: int): HclValue =
  let v = raw.strip()
  if v.len == 0:
    raise newException(HclParseError, &"linia {lineNo}: brak wartości po '=' (pusta prawa strona)")
  if v[0] == '"':
    let (s, nextIdx) = readQuotedString(v, 0, lineNo)
    if v[nextIdx .. ^1].strip().len > 0:
      raise newException(HclParseError, &"linia {lineNo}: nieoczekiwane znaki po zamkniętym stringu")
    result = HclValue(kind: hvString, strVal: s)
  elif v == "true" or v == "false":
    result = HclValue(kind: hvBool, boolVal: v == "true")
  elif v[0] == '[':
    if v[^1] != ']':
      raise newException(HclParseError, &"linia {lineNo}: niedomknięta lista (brakujący końcowy ']')")
    let items = splitHclList(v[1 ..< v.high], lineNo)
    result = HclValue(kind: hvList, listVal: items)
  elif looksNumeric(v):
    if '.' in v:
      try:
        result = HclValue(kind: hvFloat, floatVal: parseFloat(v))
      except ValueError:
        raise newException(HclParseError, &"linia {lineNo}: nieprawidłowa liczba zmiennoprzecinkowa '{v}'")
    else:
      try:
        result = HclValue(kind: hvInt, intVal: parseInt(v))
      except ValueError:
        raise newException(HclParseError, &"linia {lineNo}: nieprawidłowa liczba całkowita '{v}'")
  else:
    # Nieznana, niecudzysłowiona wartość (np. literówka zamiast "true"/
    # liczby/listy/stringa w cudzysłowie) -- zamiast cicho przyjąć to
    # jako string dosłownie, ostrzegamy: to niemal zawsze błąd configu.
    raise newException(HclParseError,
      &"linia {lineNo}: nierozpoznana wartość '{v}' -- oczekiwano stringa w cudzysłowach, " &
      "liczby (w tym ujemnej/zmiennoprzecinkowej), true/false albo listy [\"a\",\"b\"]")

proc parseHcl*(source: string): HclBlock =
  ## Parsuje cały dokument HCL, zwracając "wirtualny" blok główny (root),
  ## którego `children` to bloki najwyższego poziomu, a `attrs` to
  ## atrybuty zdefiniowane poza blokami. Rzuca `HclParseError` (z numerem
  ## linii) przy niedomkniętym bloku/stringu/liście albo nierozpoznanej
  ## wartości -- zamiast po cichu zwrócić coś innego, niż operator napisał.
  ##
  ## UWAGA: parseHcl NIE odrzuca sam z siebie wielu bloków o tej samej
  ## nazwie na tym samym poziomie (`package {} ... package {}`) -- to
  ## sprawdza wywołujący (manifest.nim), który zna semantykę "jeden
  ## `package{}` na plik `zpk.build`"; parser HCL jako taki jest formatem
  ## ogólnego przeznaczenia i nie powinien tego narzucać.
  result = newHclBlock("root")
  var stack: seq[HclBlock] = @[result]
  var openLines: seq[int] = @[0]  ## linia otwarcia każdego bloku na stosie (root = 0)

  for idx, rawLine in source.splitLines().pairs():
    let lineNo = idx + 1
    var line = rawLine.strip()
    # usuń komentarze (# lub //), ale NIE wewnątrz cudzysłowów
    line = block:
      var inStr = false
      var cut = line.len
      var k = 0
      while k < line.len:
        if line[k] == '"' and (k == 0 or line[k-1] != '\\'): inStr = not inStr
        elif not inStr and line[k] == '#':
          cut = k; break
        elif not inStr and line[k] == '/' and k + 1 < line.len and line[k+1] == '/':
          cut = k; break
        inc k
      line[0 ..< cut].strip()
    if line.len == 0: continue

    if line.endsWith("{"):
      var header = line[0 ..< line.high].strip()
      var blockName = header
      let quoteStart = header.find('"')
      if quoteStart >= 0:
        let quoteEnd = header.rfind('"')
        if quoteEnd <= quoteStart:
          raise newException(HclParseError, &"linia {lineNo}: niedomknięty string w nagłówku bloku")
        blockName = header[quoteStart+1 ..< quoteEnd]
      else:
        blockName = header.strip()
      if blockName.len == 0:
        raise newException(HclParseError, &"linia {lineNo}: blok bez nazwy przed '{{'")
      let blk = newHclBlock(blockName)
      stack[^1].children.add(blk)
      stack.add(blk)
      openLines.add(lineNo)
    elif line == "}":
      if stack.len <= 1:
        raise newException(HclParseError, &"linia {lineNo}: nadmiarowy '}}' bez odpowiadającego otwarcia")
      discard stack.pop()
      discard openLines.pop()
    elif '=' in line:
      let idxEq = line.find('=')
      let key = line[0 ..< idxEq].strip()
      if key.len == 0:
        raise newException(HclParseError, &"linia {lineNo}: brak nazwy klucza przed '='")
      let valRaw = line[idxEq+1 .. ^1].strip()
      stack[^1].attrs[key] = parseValue(valRaw, lineNo)
    else:
      raise newException(HclParseError,
        &"linia {lineNo}: nierozpoznana linia (oczekiwano 'blok {{', '}}' albo 'klucz = wartość'): {line}")

  if stack.len > 1:
    raise newException(HclParseError,
      &"niedomknięty blok '{stack[^1].name}' otwarty w linii {openLines[^1]} (brakujący '}}' do końca pliku)")

proc getStr*(blk: HclBlock, key: string, default = ""): string =
  if blk.attrs.hasKey(key) and blk.attrs[key].kind == hvString:
    blk.attrs[key].strVal
  else: default

proc getBool*(blk: HclBlock, key: string, default = false): bool =
  if blk.attrs.hasKey(key) and blk.attrs[key].kind == hvBool:
    blk.attrs[key].boolVal
  else: default

proc getInt*(blk: HclBlock, key: string, default = 0): int =
  if blk.attrs.hasKey(key) and blk.attrs[key].kind == hvInt:
    blk.attrs[key].intVal
  else: default

proc getFloat*(blk: HclBlock, key: string, default = 0.0): float =
  if blk.attrs.hasKey(key) and blk.attrs[key].kind == hvFloat:
    blk.attrs[key].floatVal
  else: default

proc getList*(blk: HclBlock, key: string, default: seq[string] = @[]): seq[string] =
  if blk.attrs.hasKey(key) and blk.attrs[key].kind == hvList:
    blk.attrs[key].listVal
  else: default

proc findBlock*(blk: HclBlock, name: string): HclBlock =
  for c in blk.children:
    if c.name == name: return c
  return nil

proc findAllBlocks*(blk: HclBlock, name: string): seq[HclBlock] =
  ## Zwraca WSZYSTKIE bezpośrednie dzieci o danej nazwie -- w
  ## przeciwieństwie do `findBlock`, które po cichu zwraca tylko
  ## pierwsze trafienie. Używane w manifest.nim do wykrywania
  ## przypadkowo zduplikowanych bloków `package { }` / `recipe { }` /
  ## `release { }` w `zpk.build` (np. wynik nieudanego scalenia
  ## dwóch plików), które wcześniej były po cichu ignorowane poza
  ## pierwszym wystąpieniem.
  result = @[]
  for c in blk.children:
    if c.name == name: result.add c
