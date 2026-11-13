# F40 claude-20261112 additive producer: quantity accuracy with typed binding values.
#
# ruby-feature-additions/v1 recorded the six accuracy rows correctly, but a request
# builder that flattens {decimal: "2.5"} into the plain String "2.5" turns a limited
# BigDecimal binding into an exact Rational one. This producer pins both classes.
# Each row carries:
#   inputs        the Ruby binding values, wire-encoded by class (decimal/rational/binary64,
#                 Integer as a JSON number, the String control as {"string": text})
#   request       a plurimath.evaluate.quantity/1 request whose binding values keep the
#                 Ruby class: {"decimal": s} for BigDecimal, {"rational": [n, d]} for
#                 Rational, {"binary64": hex} for Float; Integer and String stay plain
#                 decimal Strings (exact Rational in Ruby's request decoder)
#   library       Formula#evaluate_quantity with the typed Ruby values (String controls are
#                 decoded exactly as EvaluationRequest::Quantity#magnitude does: Rational(text))
#   ruby_wire     Plurimath::EvaluationRequest.call(request) at this head, verbatim, or the
#                 exception class and first message line when the entry point raises
require "json"
require "bigdecimal"
require "plurimath"
require "unitsml"
require "plurimath/evaluation_request"

def wire(value)
  case value
  when nil, true, false, String, Integer then value
  when Symbol then { "symbol" => value.to_s }
  when Rational then { "rational" => [value.numerator.to_s, value.denominator.to_s] }
  when BigDecimal then { "decimal" => value.to_s("F") }
  when Float then { "binary64" => [value].pack("G").unpack1("H*") }
  when Array then value.map { |item| wire(item) }
  when Hash then value.to_h { |key, item| [key.to_s, wire(item)] }
  else raise TypeError, "Unserialized value: #{value.class}"
  end
end

# Typed source value: String controls are kept as Text so the class survives until
# the request is built.
Text = Struct.new(:text)

def request_value(value)
  case value
  when Text then value.text
  when Integer then value.to_s
  when BigDecimal, Rational, Float then wire(value)
  else raise TypeError, value.class.name
  end
end

def library_value(value) = value.is_a?(Text) ? Rational(value.text) : value

def input_wire(value)
  return { "string" => value.text } if value.is_a?(Text)

  row = wire(value)
  if value.is_a?(BigDecimal)
    again = BigDecimal(value.to_s("F"))
    row = row.merge("precision" => value.precision, "wire_reparse_precision" => again.precision,
                    "wire_reparse_equal" => again == value)
  end
  row
end

def ast(formula)
  return { "type" => "variable", "name" => formula } if formula.match?(/\A[a-z]+\z/)

  op = formula[/[*+\/-]/]
  left, right = formula.split(op)
  { "type" => "binary", "operator" => op,
    "left" => { "type" => "variable", "name" => left }, "right" => { "type" => "variable", "name" => right } }
end

ROWS = []

def row(family, id, formula, inputs, note)
  request = { "schema" => "plurimath.evaluate.quantity/1", "ast" => ast(formula),
              "bindings" => inputs.to_h { |k, (v, u)| [k.to_s, { "value" => request_value(v), "unit" => u }] } }
  out = { family: family, id: id, note: note, formula: formula,
          inputs: inputs.to_h { |k, (v, u)| [k, { "value" => input_wire(v), "unit" => u }] },
          request: request }
  begin
    bindings = inputs.to_h { |k, (v, u)| [k, Unitsml::Quantity.new(value: library_value(v), unit: u)] }
    res = Plurimath::Math.parse(formula, :asciimath).evaluate_quantity(bindings)
    out[:library] = { outcome: "ok", value: res.value.value, value_class: res.value.value.class.name,
                      unit: res.value.norm_text, accuracy: res.accuracy }
  rescue StandardError => e
    out[:library] = { outcome: "error", error_class: e.class.name, message: e.message }
  end
  begin
    out[:ruby_wire] = Plurimath::EvaluationRequest.call(JSON.generate(request))
  rescue StandardError => e
    # Recorded, not normalised: the request entry point raised instead of answering.
    out[:ruby_wire] = { raised: e.class.name, message: e.message.lines.first.to_s.strip }
  end
  ROWS << out
end

BD = ->(s) { BigDecimal(s) }
A = "accuracy_classes_typed"

# The six original ruby-feature-additions/v1 accuracy rows, same Ruby values.
row(A, "exact-rational", "x*y", { x: [Rational(5, 2), "m"], y: [3, "s"] }, "original row")
row(A, "limited-float", "x*y", { x: [2.5, "m"], y: [3, "s"] }, "original row")
row(A, "limited-decimal", "x*y", { x: [BD["2.50"], "m"], y: [3, "s"] }, "original row")
row(A, "least-precise-wins-decimal", "x*y", { x: [BD["2.50"], "m"], y: [BD["3.1"], "s"] }, "original row")
row(A, "least-precise-wins-float", "x*y", { x: [BD["2.50"], "m"], y: [3.0, "s"] }, "original row")
row(A, "limited-sum-same-unit", "x+y", { x: [BD["1.5"], "m"], y: [2, "m"] }, "original row")

# String-exact controls: the same digits as plain Strings stay exact Rationals.
S = "string_exact_controls"
row(S, "string-exact-product", "x*y", { x: [Text.new("2.50"), "m"], y: [Text.new("3"), "s"] }, "limited-decimal digits as Strings")
row(S, "string-exact-least-precise", "x*y", { x: [Text.new("2.50"), "m"], y: [Text.new("3.1"), "s"] }, "least-precise-wins-decimal digits as Strings")
row(S, "string-exact-sum-same-unit", "x+y", { x: [Text.new("1.5"), "m"], y: [Text.new("2"), "m"] }, "limited-sum-same-unit digits as Strings")
row(S, "string-exact-float-digits", "x*y", { x: [Text.new("2.5"), "m"], y: [Text.new("3.0"), "s"] }, "least-precise-wins-float digits as Strings")
row(S, "string-exact-third", "x/y", { x: [Text.new("1"), "m"], y: [Text.new("3"), "s"] }, "non-terminating quotient stays an exact Rational")

# Unused bindings: every bound quantity enters the accuracy combination.
U = "unused_binding_controls"
row(U, "unused-decimal-binding", "x*y", { x: [Rational(5, 2), "m"], y: [3, "s"], z: [BD["1.5"], "m"] }, "z is bound but not used")
row(U, "unused-float-binding", "x*y", { x: [Rational(5, 2), "m"], y: [3, "s"], z: [1.5, "m"] }, "z is bound but not used")
row(U, "unused-string-binding", "x*y", { x: [BD["2.50"], "m"], y: [3, "s"], z: [Text.new("1.5"), "m"] }, "z is bound but not used")

# Precision: limited_<n> follows BigDecimal#precision of each operand; the least wins.
P = "decimal_precision_controls"
row(P, "precision-trailing-zeros", "x*y", { x: [BD["2.500"], "m"], y: [3, "s"] }, "trailing zeros do not add precision")
row(P, "precision-six-digits", "x*y", { x: [BD["2.54321"], "m"], y: [3, "s"] }, "")
row(P, "precision-least-of-two", "x*y", { x: [BD["1.23456"], "m"], y: [BD["2.0"], "s"] }, "")
row(P, "precision-integer-decimal", "x*y", { x: [BD["1200"], "m"], y: [1, "s"] }, "integral BigDecimal")
row(P, "precision-small-magnitude", "x*y", { x: [BD["0.000125"], "m"], y: [4, "s"] }, "leading zeros")
row(P, "precision-quotient", "x/y", { x: [BD["1"], "m"], y: [BD["3"], "s"] }, "non-terminating decimal quotient")
row(P, "precision-decimal-times-rational", "x*y", { x: [BD["2.5"], "m"], y: [Rational(1, 3), "s"] }, "")
row(P, "precision-sum-unit-conversion", "x+y", { x: [BD["1.5"], "km"], y: [BD["250.0"], "m"] }, "right operand converted to km")
row(P, "precision-difference", "x-y", { x: [BD["10.25"], "m"], y: [BD["0.5"], "m"] }, "")

# Float operation rounding: binary64 results recorded bit-exact.
F = "float_rounding"
row(F, "float-sum-tenths", "x+y", { x: [0.1, "m"], y: [0.2, "m"] }, "0.1+0.2 rounding")
row(F, "float-product-tenth", "x*y", { x: [0.1, "m"], y: [3, "s"] }, "")
row(F, "float-quotient", "x/y", { x: [1.0, "m"], y: [3.0, "s"] }, "")
row(F, "float-times-decimal", "x*y", { x: [0.1, "m"], y: [BD["3.3"], "s"] }, "mixed Float and BigDecimal")
row(F, "float-times-rational", "x*y", { x: [0.1, "m"], y: [Rational(1, 3), "s"] }, "mixed Float and Rational")
row(F, "float-sum-unit-conversion", "x+y", { x: [0.1, "km"], y: [1.0, "m"] }, "right operand converted to km")

# Added after R's 13 source probes (bridge 2026-11-12 20:11 PKT); values are this
# producer's own captures. Earlier rows above are unchanged.
row(U, "unused-decimal-binding-single-variable", "x", { x: [2, "m"], unused: [BD["0.01"], "s"] }, "formula is one variable; unused is bound but not used")
row(U, "unused-float-binding-single-variable", "x", { x: [2, "m"], unused: [0.1, "s"] }, "formula is one variable; unused is bound but not used")
row(P, "decimal-zero-precision", "x", { x: [BD["0.0"], "m"] }, "zero has precision 0")
row(P, "decimal-leading-zero-precision", "x*y", { x: [BD["0.01"], "m"], y: [BD["100.0"], "s"] }, "the result re-enters the accuracy combination with its own precision")
row(P, "decimal-conversion-neighbor", "x+y", { x: [BD["0.1"], "m"], y: [BD["0.2"], "cm"] }, "right operand converted to m")
row(F, "float-rounding-neighbor", "x*y", { x: [0.1, "m"], y: [0.2, "s"] }, "binary64 product rounding")
row(F, "float-decimal-neighbor", "x*y", { x: [BD["0.1"], "m"], y: [0.2, "s"] }, "mixed BigDecimal and Float")

ROWS.each { |r| puts JSON.generate(wire(r)) }
