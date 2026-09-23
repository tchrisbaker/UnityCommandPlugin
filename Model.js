// Pure logic for the Unity Commander plugin: command/parameter shaping,
// fuzzy search scoring, CLI argument building, and response classification.
// No QML/Quickshell dependencies so this can be unit-reasoned about (and
// loaded with `import "Model.js" as Model`) in isolation.

// The unit/manager dropdowns are this plugin's own convention (backed by
// <namespace>get_unit_names / <namespace>get_manager_names commands - see
// refreshUnitNames/refreshManagerNames in Window.qml), so they only kick in
// for commands under the user's configured namespace, not arbitrary/built-in
// Unity commands that happen to have a parameter named e.g. "unit".
function isNamespacedCommand(commandName, namespace) {
  if (!namespace) return false
  return String(commandName || "").indexOf(namespace) === 0
}

function isUnitParam(param) {
  return String((param && param.name) || "").toLowerCase().indexOf("unit") !== -1
}

function isManagerParam(param) {
  return String((param && param.name) || "").toLowerCase().indexOf("manager") !== -1
}

// Which input widget a parameter should render as. `commandName`/`namespace`
// are optional so existing non-namespace-aware callers keep working; without
// them the unit/manager dropdowns are simply unavailable.
function fieldKind(param, commandName, namespace) {
  var type = (param && param.type) || ""
  if (type === "Boolean") return "boolean"
  if (isNamespacedCommand(commandName, namespace)) {
    if (isUnitParam(param)) return "unit"
    if (isManagerParam(param)) return "manager"
  }
  if (type === "Int32" || type === "Int64") return "int"
  if (type === "Single" || type === "Double") return "float"
  return "text"
}

function defaultValueFor(param) {
  var kind = fieldKind(param)
  var raw = param ? param.defaultValue : undefined
  if (kind === "boolean") return raw === true
  if (kind === "int") return (typeof raw === "number") ? raw : 0
  if (raw === null || raw === undefined) return ""
  return String(raw)
}

// Fresh { paramName: value } map with every parameter defaulted, so a form
// always starts from a known-good state when a command is selected.
function defaultValues(command) {
  var values = ({})
  var params = (command && command.parameters) || []
  for (var i = 0; i < params.length; i++) values[params[i].name] = defaultValueFor(params[i])
  return values
}

// Case-insensitive fuzzy subsequence match. Every character of `query`
// must appear in `text` in order, but not necessarily contiguously.
// Returns null when there's no match, otherwise a score where higher is a
// better match (consecutive runs, small gaps, and early starts score best).
function fuzzyScore(query, text) {
  var q = String(query || "").toLowerCase()
  var t = String(text || "").toLowerCase()
  if (q.length === 0) return 0
  if (t.length === 0) return null

  var score = 0
  var qi = 0
  var lastMatch = -1
  var consecutive = 0
  var firstMatch = -1

  for (var ti = 0; ti < t.length && qi < q.length; ti++) {
    if (t.charAt(ti) === q.charAt(qi)) {
      if (firstMatch === -1) firstMatch = ti
      var gap = lastMatch === -1 ? 0 : (ti - lastMatch - 1)
      score += Math.max(1, 10 - gap)
      if (lastMatch === ti - 1) {
        consecutive++
        score += consecutive * 2
      } else {
        consecutive = 0
      }
      lastMatch = ti
      qi++
    }
  }

  if (qi < q.length) return null
  score += Math.max(0, 6 - firstMatch)
  return score
}

// Sort `commands` (each with `name`/`description`) by fuzzy match quality
// against `query`. Name matches are weighted above description-only
// matches. Empty query returns the list unchanged.
function filterCommands(commands, query) {
  var list = commands || []
  var q = String(query || "").trim()
  if (q.length === 0) return list.slice()

  var scored = []
  for (var i = 0; i < list.length; i++) {
    var cmd = list[i]
    var nameScore = fuzzyScore(q, cmd.name)
    var descScore = fuzzyScore(q, cmd.description)
    var best = null
    if (nameScore !== null) best = nameScore * 3 + 200
    if (descScore !== null) best = (best === null) ? descScore : Math.max(best, descScore)
    if (best !== null) scored.push({ cmd: cmd, score: best })
  }
  scored.sort(function(a, b) { return b.score - a.score })

  var out = []
  for (var j = 0; j < scored.length; j++) out.push(scored[j].cmd)
  return out
}

// Build the `unity cmd <name> --paramA valueA ... --json` argv for a
// command given its current form values. Optional blank fields are
// omitted entirely so the CLI's own default applies; booleans are always
// passed explicitly since a checkbox always has a definite state.
function buildArgs(command, values) {
  var args = ["cmd", String(command.name)]
  var params = command.parameters || []
  for (var i = 0; i < params.length; i++) {
    var p = params[i]
    var kind = fieldKind(p)
    var v = values ? values[p.name] : undefined

    if (kind === "boolean") {
      args.push("--" + p.name, v ? "true" : "false")
      continue
    }
    if (v === undefined || v === null || String(v) === "") continue
    args.push("--" + p.name, String(v))
  }
  args.push("--json")
  return args
}

// Required parameters (excluding booleans, which always carry a value)
// still missing a value. Non-empty means the Run button may proceed.
function missingRequiredFields(command, values) {
  var missing = []
  var params = (command && command.parameters) || []
  for (var i = 0; i < params.length; i++) {
    var p = params[i]
    if (!p.required || fieldKind(p) === "boolean") continue
    var v = values ? values[p.name] : undefined
    if (v === undefined || v === null || String(v) === "") missing.push(p.name)
  }
  return missing
}

// Message patterns that indicate the CLI never reached a running Unity
// Editor/Player at all, as opposed to reaching it and getting an error
// back. Distinguishing these is the whole point of the plugin's error UI:
// one needs a reconnect, the other needs different parameters.
var UNREACHABLE_PATTERNS = [
  /no pipeline runtime instance found/i,
  /no running unity player found/i,
  /econnrefused/i,
  /econnreset/i,
  /etimedout/i,
  /ehostunreach/i,
  /enotfound/i,
  /could not connect/i,
  /connection refused/i,
  /timed out while connecting/i,
  /unable to connect/i,
  /fetch failed/i,
  /command not found: unity/i,
  /no such file or directory/i
]

function isUnreachableMessage(message) {
  var m = String(message || "")
  for (var i = 0; i < UNREACHABLE_PATTERNS.length; i++) {
    if (UNREACHABLE_PATTERNS[i].test(m)) return true
  }
  return false
}

// Classify one finished `unity cmd ... --json` invocation.
// status is one of:
//   "success"       - executed cleanly, no logical error in the result
//   "commandError"  - reached Unity (or the CLI) but the command itself
//                      failed/threw - fix params, don't reconnect
//   "unreachable"   - never reached a running Unity Editor/Player
function classifyResponse(stdoutText, stderrText) {
  var parsed = null
  try { parsed = JSON.parse(stdoutText) } catch (e) { parsed = null }

  if (parsed === null) {
    var raw = String(stderrText || stdoutText || "").trim() || "The unity command produced no output."
    return {
      status: isUnreachableMessage(raw) ? "unreachable" : "commandError",
      message: raw,
      payload: null
    }
  }

  if (parsed.success === false) {
    var errs = parsed.errors || []
    var msg = errs.length > 0
      ? errs.map(function(e) { return (e && e.message) || String(e) }).join("\n")
      : "Unknown error."
    return {
      status: isUnreachableMessage(msg) ? "unreachable" : "commandError",
      message: msg,
      payload: parsed
    }
  }

  var result = parsed.data ? parsed.data.result : undefined
  if (result && typeof result === "object" && !Array.isArray(result) && typeof result.error === "string") {
    return { status: "commandError", message: result.error, payload: parsed }
  }

  return { status: "success", message: "", payload: parsed }
}

function parseCommandList(stdoutText) {
  var parsed = JSON.parse(stdoutText)
  if (!parsed || parsed.success !== true) throw new Error("listing failed")
  var commands = (parsed.data && parsed.data.commands) || []
  var target = (parsed.data && parsed.data.target) || {}
  return { commands: commands, projectPath: target.projectPath || "" }
}

// get_unit_names / get_manager_names return a plain string array on
// success, or `{ error: "..." }` when there's nothing to report - both
// resolve to an empty option list rather than throwing, since an empty
// scene is a normal state, not a failure.
function parseNameList(stdoutText) {
  var parsed = null
  try { parsed = JSON.parse(stdoutText) } catch (e) { return [] }
  if (!parsed || parsed.success !== true) return []
  var result = parsed.data ? parsed.data.result : null
  return Array.isArray(result) ? result : []
}

// "someCamelKey" / "some_snake_key" -> "Some Camel Key". Purely cosmetic,
// used to turn raw JSON keys from Unity into readable row labels.
function humanizeKey(key) {
  var s = String(key === undefined || key === null ? "" : key)
  s = s.replace(/([a-z0-9])([A-Z])/g, "$1 $2")
  s = s.replace(/[_-]+/g, " ")
  s = s.replace(/\s+/g, " ").trim()
  if (s.length === 0) return s
  return s.replace(/\b\w/g, function(c) { return c.toUpperCase() })
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function formatPrimitive(value) {
  if (value === null || value === undefined || value === "") return "—"
  if (typeof value === "boolean") return value ? "Yes" : "No"
  return String(value)
}

// A short "title" for a list item, taken from its first field - e.g. for
// { manager: "Enemy Manager (Ranged)", state: "Idle", ... } that's
// "Enemy Manager (Ranged)". Used to make "#1"/"#2" list headers read as
// "#1 Enemy Manager (Ranged)" instead of a bare, meaningless index. Returns
// "" (no title) when the first field is missing, blank, or itself an
// object/array - a title should be one short readable value, not a blob.
function firstValueLabel(item) {
  var raw
  if (isPlainObject(item)) {
    var keys = Object.keys(item)
    if (keys.length === 0) return ""
    raw = item[keys[0]]
  } else if (Array.isArray(item)) {
    if (item.length === 0) return ""
    raw = item[0]
  } else {
    raw = item
  }
  if (raw === null || raw === undefined || raw === "" || typeof raw === "object") return ""
  var text = formatPrimitive(raw)
  return text.length > 40 ? text.substring(0, 39) + "…" : text
}

// Recursively turn a JSON value into a list of display rows for the QML
// side. Each row is one of:
//   { kind: "section", depth, label }                     - a plain heading (nested object)
//   { kind: "row", depth, label, value }                   - one label: value line
//   { kind: "group", depth, label, index, rows }           - one foldable list item,
//                                                             carrying its own nested rows
// `label` is already humanized; `depth` drives indentation. A "group" is
// self-contained (its `rows` are never spliced into the parent list) so the
// QML side can fold/unfold it independently of its siblings.
function buildRows(value, label, depth) {
  if (Array.isArray(value)) {
    if (value.length === 0) return [{ kind: "row", depth: depth, label: label, value: "(empty list)" }]

    var allPrimitive = value.every(function(v) { return v === null || typeof v !== "object" })
    if (allPrimitive) return [{ kind: "row", depth: depth, label: label, value: value.map(formatPrimitive).join(", ") }]

    var rows = []
    if (label) rows.push({ kind: "section", depth: depth, label: label })
    var childDepth = label ? depth + 1 : depth
    for (var i = 0; i < value.length; i++) {
      rows.push({
        kind: "group",
        depth: childDepth,
        label: "#" + (i + 1),
        title: firstValueLabel(value[i]),
        index: i,
        rows: buildRows(value[i], "", childDepth + 1)
      })
    }
    return rows
  }

  if (isPlainObject(value)) {
    var keys = Object.keys(value)
    if (keys.length === 0) return [{ kind: "row", depth: depth, label: label, value: "(empty)" }]

    var objRows = []
    if (label) objRows.push({ kind: "section", depth: depth, label: label })
    var childDepth2 = label ? depth + 1 : depth
    for (var k = 0; k < keys.length; k++) {
      objRows = objRows.concat(buildRows(value[keys[k]], humanizeKey(keys[k]), childDepth2))
    }
    return objRows
  }

  return [{ kind: "row", depth: depth, label: label, value: formatPrimitive(value) }]
}

// Entry point: flatten any JSON value (object, array, or primitive) for
// human-readable display. A bare primitive/array-of-primitives becomes a
// single unlabeled row.
function flattenForDisplay(value) {
  if (value === null || value === undefined) return [{ kind: "row", depth: 0, label: "", value: "(no result)" }]
  if (typeof value !== "object") return [{ kind: "row", depth: 0, label: "", value: formatPrimitive(value) }]
  var rows = buildRows(value, "", 0)
  if (rows.length === 0) return [{ kind: "row", depth: 0, label: "", value: "(empty)" }]
  return rows
}

// Pull the actual command result out of the full `unity cmd --json` response
// envelope ({ success, data: { command, parameters, result, target }, ... }).
function extractResult(payload) {
  if (!payload) return undefined
  var data = payload.data
  return data ? data.result : undefined
}

if (typeof module !== "undefined") {
  module.exports = {
    isUnitParam: isUnitParam,
    isManagerParam: isManagerParam,
    fieldKind: fieldKind,
    defaultValueFor: defaultValueFor,
    defaultValues: defaultValues,
    fuzzyScore: fuzzyScore,
    filterCommands: filterCommands,
    buildArgs: buildArgs,
    missingRequiredFields: missingRequiredFields,
    isUnreachableMessage: isUnreachableMessage,
    classifyResponse: classifyResponse,
    parseCommandList: parseCommandList,
    parseNameList: parseNameList,
    humanizeKey: humanizeKey,
    firstValueLabel: firstValueLabel,
    formatPrimitive: formatPrimitive,
    flattenForDisplay: flattenForDisplay,
    extractResult: extractResult
  }
}
