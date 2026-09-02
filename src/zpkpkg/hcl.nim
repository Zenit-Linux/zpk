import std/[tables, strutils, strformat]
import hclnim as hcln

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
    ## mis-parsować, bo cichy błąd konfiguracji w produkcyjnym
    ## `zpk.build` jest dużo gorszy niż `quit(1)` z jasnym miejscem
    ## problemu. Patrz też komentarz modułu wyżej.

proc newHclBlock*(name: string): HclBlock =
  HclBlock(name: name, attrs: initTable[string, HclValue](), children: @[])

# --- obejście buga hcl_nim przy liczbach ze znakiem ------------------------

proc looksNumericZpk(v: string): bool =
  ## To samo kryterium co w oryginalnym, ręcznym parserze zpk sprzed
  ## migracji: opcjonalny wiodący `+`/`-`, potem sama mieszanka cyfr i
  ## kropek (w tym `.5` bez wiodącego zera), z opcjonalnym wykładnikiem
  ## `e`/`E`. Musi trafić choć jedną cyfrę.
  if v.len == 0: return false
  var i = 0
  if v[0] == '-' or v[0] == '+': inc i
  if i >= v.len: return false
  var sawDigit = false
  var sawExp = false
  while i < v.len:
    let c = v[i]
    if c.isDigit:
      sawDigit = true
    elif c == '.':
      discard
    elif (c == 'e' or c == 'E') and sawDigit and not sawExp:
      sawExp = true
      inc i
      if i < v.len and (v[i] == '+' or v[i] == '-'): inc i
      continue
    else:
      return false
    inc i
  sawDigit

proc recoverSignedNumber(exprSrc: string): string =
  ## `hcl_nim` skleja rozjechane tokeny liczby ze znakiem spacją (patrz
  ## komentarz modułu) -- oryginalny tekst źródłowy nigdy nie miał tam
  ## spacji, więc ich usunięcie bezpiecznie odtwarza to, co użytkownik
  ## faktycznie napisał (`"-2 .5"` -> `"-2.5"`).
  exprSrc.replace(" ", "")

# --- konwersja drzewa hcl_nim -> wąski model zpk ---------------------------

proc stripLineCol(rawMsg: string): string =
  ## Komunikaty błędów hcl_nim kończą się " (line N, col M)" -- ten
  ## fragment i tak dublujemy własnym "linia {N}: " na przedzie (patrz
  ## `wrapAsHclParseError`), więc obcinamy go, żeby nie pokazywać tego
  ## samego numeru linii dwa razy w jednym komunikacie.
  let idx = rawMsg.rfind(" (line ")
  if idx >= 0: rawMsg[0 ..< idx] else: rawMsg

proc wrapAsHclParseError(line: int, msg: string): ref HclParseError =
  newException(HclParseError, &"linia {line}: {stripLineCol(msg)}")

proc parseRecoveredNumber(line: int, joined: string): HclValue =
  if '.' in joined or 'e' in joined or 'E' in joined:
    try:
      HclValue(kind: hvFloat, floatVal: parseFloat(joined))
    except ValueError:
      raise wrapAsHclParseError(line, &"nieprawidłowa liczba zmiennoprzecinkowa '{joined}'")
  else:
    try:
      HclValue(kind: hvInt, intVal: parseInt(joined))
    except ValueError:
      raise wrapAsHclParseError(line, &"nieprawidłowa liczba całkowita '{joined}'")

proc describeUnsupported(n: hcln.HclNode): string =
  ## Tekst wartości do komunikatu błędu dla węzłów spoza wąskiego
  ## podzbioru, jaki `zpk.build` rozumie (patrz `convertValue`).
  case n.kind
  of hcln.nkExpr: n.exprSrc
  of hcln.nkNull: "null"
  of hcln.nkObject: "{ ... }"
  of hcln.nkHeredoc: "<<" & n.heredocTag & " ... " & n.heredocTag
  else: "?"

proc scalarToString(n: hcln.HclNode): string =
  ## Element listy zredukowany do "surowego" stringa -- zgodnie z
  ## dotychczasowym modelem `HclValue.hvList: seq[string]` (patrz
  ## `manifest.nim`/`getList`), gdzie lista jest zawsze listą stringów
  ## niezależnie od tego, czy w źródle element miał cudzysłów, czy był
  ## liczbą/bool-em. Nieujęty w cudzysłów, nierozpoznany element listy
  ## był w oryginalnym parserze zawsze przyjmowany dosłownie (bez
  ## walidacji) -- ta sama tolerancja jest zachowana tutaj dla `nkExpr`,
  ## które nie da się odzyskać jako liczba.
  case n.kind
  of hcln.nkString: n.strVal
  of hcln.nkNumber:
    if n.isInt: $n.intVal else: $n.numVal
  of hcln.nkBool: $n.boolVal
  of hcln.nkExpr:
    let joined = recoverSignedNumber(n.exprSrc)
    if looksNumericZpk(joined): joined else: n.exprSrc
  else:
    raise wrapAsHclParseError(n.line,
      &"nierozpoznany element listy '{describeUnsupported(n)}' -- " &
      "oczekiwano stringa w cudzysłowach, liczby, albo true/false")

proc convertValue(n: hcln.HclNode): HclValue =
  case n.kind
  of hcln.nkString:
    HclValue(kind: hvString, strVal: n.strVal)
  of hcln.nkNumber:
    if n.isInt:
      HclValue(kind: hvInt, intVal: int(n.intVal))
    else:
      HclValue(kind: hvFloat, floatVal: n.numVal)
  of hcln.nkBool:
    HclValue(kind: hvBool, boolVal: n.boolVal)
  of hcln.nkList:
    var items: seq[string] = @[]
    for it in n.items: items.add scalarToString(it)
    HclValue(kind: hvList, listVal: items)
  of hcln.nkExpr:
    let joined = recoverSignedNumber(n.exprSrc)
    if looksNumericZpk(joined):
      parseRecoveredNumber(n.line, joined)
    else:
      raise wrapAsHclParseError(n.line,
        &"nierozpoznana wartość '{n.exprSrc}' -- oczekiwano stringa w cudzysłowach, " &
        "liczby (w tym ujemnej/zmiennoprzecinkowej), true/false albo listy [\"a\",\"b\"]")
  else:
    raise wrapAsHclParseError(n.line,
      &"nierozpoznana wartość '{describeUnsupported(n)}' -- oczekiwano stringa w cudzysłowach, " &
      "liczby (w tym ujemnej/zmiennoprzecinkowej), true/false albo listy [\"a\",\"b\"]")

proc convertBody(items: seq[hcln.HclNode], blk: HclBlock) =
  for item in items:
    case item.kind
    of hcln.nkAttribute:
      blk.attrs[item.name] = convertValue(item.value)
    of hcln.nkBlock:
      let child = newHclBlock(item.blockType)
      convertBody(item.blockBody, child)
      blk.children.add child
    else:
      discard  # parser hcl_nim nie generuje innych węzłów na poziomie "body"

proc parseHcl*(source: string): HclBlock =
  ## Parsuje cały dokument HCL (silnik: hcl_nim, patrz komentarz modułu
  ## wyżej) i zwraca "wirtualny" blok główny (root), którego `children`
  ## to bloki najwyższego poziomu, a `attrs` to atrybuty zdefiniowane
  ## poza blokami -- dokładnie jak przed migracją na hcl_nim. Rzuca
  ## `HclParseError` (z numerem linii) przy niedomkniętym
  ## bloku/stringu/liście albo nierozpoznanej/niewspieranej wartości.
  ##
  ## UWAGA: `parseHcl` sam z siebie NIE odrzuca wielu bloków o tej
  ## samej nazwie na tym samym poziomie (`package {} ... package {}`)
  ## -- to sprawdza wywołujący (`manifest.nim`, który zna semantykę
  ## "jeden `package{}` na plik `zpk.build`"); ten moduł jako taki jest
  ## adapterem ogólnego formatu i nie powinien tego narzucać.
  var doc: hcln.HclNode
  try:
    doc = hcln.parseHcl(source, hcln.hcl2)
  except hcln.HclLexError as e:
    raise wrapAsHclParseError(e.line, e.msg)
  except hcln.HclParseError as e:
    raise wrapAsHclParseError(e.line, e.msg)
  except hcln.HclError as e:
    # Nie powinno się zdarzyć -- HclLexError/HclParseError to jedyne
    # podklasy, jakie hcl_nim obecnie rzuca -- ale gdyby przybyła nowa,
    # i tak zgłaszamy to jako błąd configu zamiast dać jej przeciekać
    # jako surowy, nieudokumentowany wyjątek z zależności.
    raise newException(HclParseError, &"błąd parsowania HCL: {e.msg}")

  result = newHclBlock("root")
  convertBody(doc.body, result)

# --- akcesory (bez zmian względem wersji sprzed migracji) ------------------

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
  ## `release { }` w `zpk.build`.
  result = @[]
  for c in blk.children:
    if c.name == name: result.add c
