function isPlainObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) && !(value instanceof SexpSymbol);
}

class SexpSymbol {
  constructor(name) {
    this.name = name;
  }
}

function sym(name) {
  return new SexpSymbol(name);
}

function writeString(value) {
  return JSON.stringify(String(value));
}

function writeAtom(value) {
  if (value instanceof SexpSymbol) return value.name;
  if (value === true) return "#t";
  if (value === false || value === null || value === undefined) return "#f";
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("cannot write non-finite number");
    return String(value);
  }
  if (typeof value === "string") return writeString(value);
  throw new Error(`cannot write S-expression atom: ${typeof value}`);
}

function writeSexp(value) {
  if (Array.isArray(value)) return `(${value.map(writeSexp).join(" ")})`;
  return writeAtom(value);
}

function sexpFields(name, fields) {
  const out = [sym(name)];
  for (const [key, value] of Object.entries(fields)) {
    if (Array.isArray(value) && value.every((item) => item instanceof SexpSymbol || typeof item !== "object")) {
      out.push([sym(key), ...value]);
    } else if (Array.isArray(value)) {
      out.push([sym(key), ...value]);
    } else {
      out.push([sym(key), value]);
    }
  }
  return out;
}

function tokenize(input) {
  const tokens = [];
  let i = 0;
  while (i < input.length) {
    const ch = input[i];
    if (/\s/.test(ch)) {
      i += 1;
    } else if (ch === ";") {
      while (i < input.length && input[i] !== "\n") i += 1;
    } else if (ch === "(" || ch === ")") {
      tokens.push({ type: ch, value: ch });
      i += 1;
    } else if (ch === '"') {
      let raw = '"';
      i += 1;
      while (i < input.length) {
        const c = input[i];
        raw += c;
        i += 1;
        if (c === "\\") {
          if (i >= input.length) throw new Error("unterminated string");
          raw += input[i];
          i += 1;
        } else if (c === '"') {
          break;
        }
      }
      if (!raw.endsWith('"')) throw new Error("unterminated string");
      tokens.push({ type: "string", value: JSON.parse(raw) });
    } else {
      let atom = "";
      while (i < input.length && !/\s/.test(input[i]) && input[i] !== "(" && input[i] !== ")") {
        atom += input[i];
        i += 1;
      }
      tokens.push({ type: "atom", value: atom });
    }
  }
  return tokens;
}

function parseAtom(atom) {
  if (atom === "#t") return true;
  if (atom === "#f") return false;
  if (/^[+-]?(?:\d+|\d+\.\d+)$/.test(atom)) return Number(atom);
  return sym(atom);
}

function parseSexp(input) {
  const tokens = tokenize(input);
  let index = 0;

  function parseOne() {
    const token = tokens[index];
    if (!token) throw new Error("unexpected end of S-expression");
    index += 1;
    if (token.type === "string") return token.value;
    if (token.type === "atom") return parseAtom(token.value);
    if (token.type === "(") {
      const list = [];
      while (tokens[index] && tokens[index].type !== ")") list.push(parseOne());
      if (!tokens[index]) throw new Error("unterminated list");
      index += 1;
      return list;
    }
    throw new Error("unexpected closing parenthesis");
  }

  const forms = [];
  while (index < tokens.length) forms.push(parseOne());
  return forms;
}

function symbolName(value) {
  return value instanceof SexpSymbol ? value.name : "";
}

function fieldList(form) {
  if (!Array.isArray(form)) return [];
  return form.slice(1).filter(Array.isArray);
}

function fieldValue(fields, name, fallback = undefined) {
  const field = fields.find((item) => symbolName(item[0]) === name);
  if (!field) return fallback;
  if (field.length <= 2) return field[1] ?? fallback;
  return field.slice(1);
}

function fieldValues(fields, name) {
  const field = fields.find((item) => symbolName(item[0]) === name);
  return field ? field.slice(1) : [];
}

function scalarString(value, fallback = "") {
  if (value === false || value === undefined || value === null) return fallback;
  return String(value);
}

function symbolStrings(values) {
  return (values || []).map((value) => value instanceof SexpSymbol ? value.name : String(value));
}

function parseData(value) {
  if (typeof value !== "string") return value;
  const trimmed = value.trim();
  if (!trimmed) return [];
  if (trimmed.startsWith("[") || trimmed.startsWith("{")) return JSON.parse(trimmed);
  const forms = parseSexp(trimmed);
  return readDataValue(forms.length === 1 ? forms[0] : [sym("list"), ...forms]);
}

function dataArray(value) {
  const parsed = parseData(value);
  return Array.isArray(parsed) ? parsed : [];
}

function dataObject(value) {
  const parsed = parseData(value);
  return isPlainObject(parsed) ? parsed : {};
}

function dataValue(value) {
  return parseData(value);
}

function writeDataValue(value) {
  if (Array.isArray(value)) return [sym("list"), ...value.map(writeDataValue)];
  if (isPlainObject(value)) {
    return [
      sym("object"),
      ...Object.entries(value).map(([key, item]) => [sym(key), writeDataValue(item)]),
    ];
  }
  if (value === null || value === undefined) return false;
  return value;
}

function readDataValue(value) {
  if (value instanceof SexpSymbol) return value.name;
  if (!Array.isArray(value)) return value;
  const tag = symbolName(value[0]);
  if (tag === "list") return value.slice(1).map(readDataValue);
  if (tag === "object") {
    const out = {};
    for (const field of value.slice(1)) {
      if (Array.isArray(field) && field[0] instanceof SexpSymbol) {
        out[field[0].name] = field.length === 2 ? readDataValue(field[1]) : field.slice(1).map(readDataValue);
      }
    }
    return out;
  }
  return value.map(readDataValue);
}

function dataText(value) {
  return writeSexp(writeDataValue(value));
}

export {
  SexpSymbol,
  sym,
  writeSexp,
  sexpFields,
  parseSexp,
  symbolName,
  fieldList,
  fieldValue,
  fieldValues,
  scalarString,
  symbolStrings,
  parseData,
  dataValue,
  dataArray,
  dataObject,
  dataText,
};
