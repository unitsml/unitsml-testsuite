# frozen_string_literal: true

# F40 F06.named_power_class: actual behaviour of the EXISTING explicit
# quantity-kind API of unitsml-ruby (Unitsml::Quantity kind:, convert_to,
# +, -, ==, primary_kind) for the unit expression "kV*A".
#
#   ruby capture-power-kind.rb PROFILE DATA_DIR > payload.jsonl
#
# The UnitsDB snapshot is loaded explicitly and read-only with
# Unitsml::Unitsdb::Database.from_db(DATA_DIR) and injected into this
# process's Unitsml::Unitsdb cache before any unit is parsed. The global
# ::Unitsdb.database loader is guarded in-process so a fallback to the
# installed gem data would fail loudly. Nothing on disk is written.
#
# Every row records what the call returned or raised. Nothing is inferred:
# a kind appears in a row only when the caller declared it or the API
# returned it. Implicit (automatic) typing of kV*A is not exercised.
require "json"
require "digest"
require "unitsml"
require "unitsdb"

PROFILE = ARGV.fetch(0)
DATA_DIR = File.expand_path(ARGV.fetch(1))

def emit(row)
  $stdout.puts JSON.generate(row)
end

def value_wire(value)
  case value
  when Rational then { "class" => "Rational", "text" => "#{value.numerator}/#{value.denominator}" }
  when Integer then { "class" => "Integer", "text" => value.to_s }
  when nil then nil
  else { "class" => value.class.name, "text" => value.to_s }
  end
end

def kind_wire(kind)
  return nil if kind.nil?

  { "id" => kind.id.to_s, "name" => kind.name, "equivalence_class" => kind.equivalence_class,
    "dimension_id" => kind.dimension_id }
end

def quantity_wire(q)
  primary = begin
    { "outcome" => "ok", "kind" => kind_wire(q.primary_kind) }
  rescue StandardError => e
    { "outcome" => "error", "error_class" => e.class.name, "message" => e.message }
  end
  { "value" => value_wire(q.value), "unit" => q.norm_text, "dimension_id" => q.dimension_id,
    "scale" => q.scale.to_s, "kind" => kind_wire(q.kind), "primary_kind" => primary }
end

def probe(id, family, call, item)
  result = yield
  wired = result.is_a?(Unitsml::Quantity) ? { "quantity" => quantity_wire(result) } : { "value" => result }
  emit({ "id" => id, "profile" => PROFILE, "family" => family, "item" => item, "call" => call,
         "outcome" => "ok", "result" => wired })
rescue StandardError => e
  emit({ "id" => id, "profile" => PROFILE, "family" => family, "item" => item, "call" => call,
         "outcome" => "error", "error_class" => e.class.name, "message" => e.message })
end

# ---------------------------------------------------- explicit snapshot ---
::Unitsdb.singleton_class.prepend(Module.new do
  def database(*)
    raise "global ::Unitsdb.database consulted; the snapshot must come from DATA_DIR"
  end
end)
context_id = Unitsml::Configuration.context.id
snapshot = Unitsml::Unitsdb::Database.from_db(DATA_DIR, context: context_id)
Unitsml::Unitsdb.reset_caches
Unitsml::Unitsdb.instance_variable_set(:@database, snapshot)

data_files = %w[quantities.yaml units.yaml dimensions.yaml prefixes.yaml scales.yaml unit_systems.yaml]
q_records = %w[NISTq187 NISTq20].to_h do |qid|
  rec = snapshot.quantities.find { |q| q.identifiers.to_a.any? { |i| i.id == qid } }
  refs = snapshot.units.select { |u| u.quantity_references.to_a.any? { |r| r.id == qid } }.map do |u|
    ref = u.quantity_references.to_a.find { |r| r.id == qid }
    { "unit" => u.identifiers.to_a.map(&:id).first, "primary" => ref.primary,
      "references" => u.quantity_references.to_a.size }
  end
  [qid, { "names" => rec.names.to_a.map(&:value), "dimension" => rec.dimension_reference&.id.to_s,
          "equivalence_class" => rec.equivalence_class, "referencing_units" => refs.sort_by { |r| r["unit"].to_s } }]
end
va_units = snapshot.units.select do |u|
  u.symbols.to_a.any? { |s| s.ascii.to_s == "VA" } ||
    u.names.to_a.any? { |n| n.value.to_s.match?(/volt.?ampere/i) }
end.map { |u| u.identifiers.to_a.map(&:id).first }
emit({ "id" => "#{PROFILE}/snapshot", "profile" => PROFILE, "family" => "snapshot",
       "loader" => "Unitsml::Unitsdb::Database.from_db(DATA_DIR, context: #{context_id.inspect}) injected as Unitsml::Unitsdb.database",
       "snapshot_in_use" => Unitsml::Unitsdb.database.equal?(snapshot),
       "data_files_sha256" => data_files.to_h { |f| [f, Digest::SHA256.file(File.join(DATA_DIR, f)).hexdigest] },
       "unitsml" => Gem.loaded_specs.fetch("unitsml").version.to_s, "unitsdb_gem" => Gem.loaded_specs.fetch("unitsdb").version.to_s, "ruby" => RUBY_VERSION,
       "quantities" => q_records, "volt_ampere_units" => va_units })

kva = ->(kind = nil, value = 3) { Unitsml::Quantity.new(value: value, unit: "kV*A", kind: kind) }
kw = ->(kind = nil, value = 3) { Unitsml::Quantity.new(value: value, unit: "kW", kind: kind) }

# 1. explicit caller-declared kind on "kV*A" (construction)
probe("construct-kva-kind-nistq187", "construction", 'Quantity.new(value: 3, unit: "kV*A", kind: "NISTq187")', 1) { kva.("NISTq187") }
probe("construct-kva-kind-nistq20", "construction", 'Quantity.new(value: 3, unit: "kV*A", kind: "NISTq20")', 1) { kva.("NISTq20") }
probe("construct-kva-kind-primary", "construction", 'Quantity.new(value: 3, unit: "kV*A", kind: :primary)', 1) { kva.(:primary) }
probe("construct-kw-kind-nistq187", "construction", 'Quantity.new(value: 3, unit: "kW", kind: "NISTq187")', 1) { kw.("NISTq187") }
probe("construct-kw-kind-primary", "construction", 'Quantity.new(value: 3, unit: "kW", kind: :primary)', 1) { kw.(:primary) }

# 2. convert_to "kW" of each typed kV*A
probe("convert-kva-nistq187-to-kw", "conversion", 'Quantity.new(value: 3, unit: "kV*A", kind: "NISTq187").convert_to("kW")', 2) { kva.("NISTq187").convert_to("kW") }
probe("convert-kva-nistq20-to-kw", "conversion", 'Quantity.new(value: 3, unit: "kV*A", kind: "NISTq20").convert_to("kW")', 2) { kva.("NISTq20").convert_to("kW") }
probe("convert-kva-untyped-to-kw", "conversion", 'Quantity.new(value: 3, unit: "kV*A").convert_to("kW")', 2) { kva.().convert_to("kW") }
probe("convert-kw-nistq187-to-kva", "conversion", 'Quantity.new(value: 3, unit: "kW", kind: "NISTq187").convert_to("kV*A")', 2) { kw.("NISTq187").convert_to("kV*A") }

# 3. typed NISTq187 with NISTq20 (add / subtract / ==), with controls
probe("add-kva-nistq187-kva-nistq20", "typed_arithmetic", 'kV*A(NISTq187) + kV*A(NISTq20)', 3) { kva.("NISTq187") + kva.("NISTq20") }
probe("sub-kva-nistq187-kva-nistq20", "typed_arithmetic", 'kV*A(NISTq187) - kV*A(NISTq20)', 3) { kva.("NISTq187") - kva.("NISTq20") }
probe("add-kva-nistq187-kw-nistq20", "typed_arithmetic", 'kV*A(NISTq187) + kW(NISTq20)', 3) { kva.("NISTq187") + kw.("NISTq20") }
probe("sub-kva-nistq187-kw-nistq20", "typed_arithmetic", 'kV*A(NISTq187) - kW(NISTq20)', 3) { kva.("NISTq187") - kw.("NISTq20") }
probe("add-kva-nistq187-kw-primary", "typed_arithmetic", 'kV*A(NISTq187) + kW(kind: :primary)', 3) { kva.("NISTq187") + kw.(:primary) }
probe("eq-kva-nistq187-kva-nistq20", "typed_arithmetic", 'kV*A(NISTq187) == kV*A(NISTq20)', 3) { kva.("NISTq187") == kva.("NISTq20") }
probe("add-kva-nistq187-kva-nistq187", "typed_arithmetic_control", 'kV*A(NISTq187) + kV*A(NISTq187)', 3) { kva.("NISTq187") + kva.("NISTq187") }
probe("add-kva-nistq187-kw-untyped", "typed_arithmetic_control", 'kV*A(NISTq187) + kW(untyped)', 3) { kva.("NISTq187") + kw.() }
probe("add-kva-untyped-kw-nistq20", "typed_arithmetic_control", 'kV*A(untyped) + kW(NISTq20)', 3) { kva.() + kw.("NISTq20") }

# 4. the untyped kV*A product and primary_kind (actual source behaviour)
probe("product-kv-times-a-untyped", "untyped_product", 'Quantity.new(value: 3, unit: "kV") * Quantity.new(value: 1, unit: "A")', 4) do
  Unitsml::Quantity.new(value: 3, unit: "kV") * Unitsml::Quantity.new(value: 1, unit: "A")
end
probe("product-kv-times-a-typed-primary-operand", "untyped_product", 'Quantity.new(value: 3, unit: "kV") * Quantity.new(value: 1, unit: "A", kind: :primary)', 4) do
  Unitsml::Quantity.new(value: 3, unit: "kV") * Unitsml::Quantity.new(value: 1, unit: "A", kind: :primary)
end
probe("parsed-kva-untyped", "untyped_product", 'Quantity.new(value: 3, unit: "kV*A")', 4) { kva.() }
probe("primary-kind-kw", "untyped_product", 'Quantity.new(value: 3, unit: "kW").primary_kind', 4) { kind_wire(kw.().primary_kind) }
