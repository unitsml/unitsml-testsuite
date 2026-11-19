# frozen_string_literal: true

# F40 F02.roundtrips producer: UnitsDB schema/provenance roundtrip vectors.
#
#   ruby capture-unitsdb-roundtrip.rb PROFILE DATA_DIR > payload.jsonl
#
# For one UnitsDB data snapshot (DATA_DIR, loaded explicitly; nothing global
# is modified) this emits one JSON line per check:
#   meta        runtime, gem versions, sha256 of every data/schema file
#   database    Unitsdb::Database.from_db(DATA_DIR).to_yaml against the
#               combined collections (unitsdb-ruby spec/unitsdb/database_spec.rb)
#   collection  Unitsdb::<Collection>.from_yaml(raw).to_yaml against raw
#               (spec/unitsdb/<collection>_spec.rb)
#   record      Unitsdb::<Entity>.from_yaml(record.to_yaml).to_yaml against the
#               record (spec/unitsdb/<entity>_spec.rb), plus the record as it
#               appears in the collection-level output
#
# Every comparison is made three ways and every mismatch is kept:
#   canon_equivalent  canon be_yaml_equivalent_to, the unitsdb-ruby contract
#   strict            recursive equality of the parsed YAML with value classes
#                     (1 vs "1" vs 1.0 differ); dropped/added keys and changed
#                     values are listed by path. Mapping key order is recorded
#                     separately (key_order_paths) and does not fail a row.
#   schema            the collection's JSON schema (draft-06 subset: $ref, type,
#                     required, properties, items, enum, const, pattern,
#                     minimum) evaluated on input and on output; keywords not
#                     evaluated are listed, never silently skipped.
# Keys a record carries that its schema does not declare are allowed by
# draft-06 here (no additionalProperties: false) and are listed as
# undeclared_keys; they are still compared like every other field.
# A row fails when canon says not equivalent, strict finds a difference, or
# the output has schema errors the input did not have.

require "json"
require "yaml"
require "digest"
require "unitsml"
require "unitsdb"
require "canon"
require "canon/rspec_matchers"

PROFILE = ARGV.fetch(0)
DATA_DIR = File.expand_path(ARGV.fetch(1))

COLLECTIONS = [
  # name, collection class (nil: none in this unitsdb), entity class
  ["prefixes", "Prefixes", "Prefix"],
  ["dimensions", "Dimensions", "Dimension"],
  ["units", "Units", "Unit"],
  ["quantities", "Quantities", "Quantity"],
  ["unit_systems", "UnitSystems", "UnitSystem"],
  ["currencies", "Currencies", "Currency"],
  ["scales", "Scales", "Scale"],
].freeze

PROVENANCE_FIELDS = %w[identifiers references quantity_references equivalence_class
                       canonical_conversion scale_reference].freeze

class Matcher
  include Canon::RSpecMatchers
end
MATCHER = Matcher.new

def emit(row)
  $stdout.write(JSON.generate(row))
  $stdout.write("\n")
end

def sort_keys(obj)
  case obj
  when Hash then obj.keys.sort.to_h { |k| [k, sort_keys(obj[k])] }
  when Array then obj.map { |v| sort_keys(v) }
  else obj
  end
end

def canonical_sha(obj)
  Digest::SHA256.hexdigest(JSON.generate(sort_keys(obj)))
end

def canon_verdict(expected_yaml, generated_yaml)
  MATCHER.be_yaml_equivalent_to(expected_yaml).matches?(generated_yaml) ? true : false
rescue StandardError => e
  "raised #{e.class}: #{e.message.lines.first.to_s.strip}"
end

def show(v)
  JSON.generate(v)[0, 300]
end

# Strict structural diff with value classes. Returns [diffs, key_order_paths].
def strict_diff(a, b, path = "$", diffs = [], order = [])
  if a.class != b.class
    diffs << { "path" => path, "kind" => "class", "input" => "#{a.class} #{show(a)}",
               "output" => "#{b.class} #{show(b)}" }
  elsif a.is_a?(Hash)
    (a.keys - b.keys).each { |k| diffs << { "path" => "#{path}.#{k}", "kind" => "dropped", "input" => show(a[k]) } }
    (b.keys - a.keys).each { |k| diffs << { "path" => "#{path}.#{k}", "kind" => "added", "output" => show(b[k]) } }
    common = a.keys & b.keys
    order << path if common != (b.keys & a.keys)
    common.each { |k| strict_diff(a[k], b[k], "#{path}.#{k}", diffs, order) }
  elsif a.is_a?(Array)
    if a.length != b.length
      diffs << { "path" => path, "kind" => "length", "input" => a.length, "output" => b.length }
    end
    [a.length, b.length].min.times { |i| strict_diff(a[i], b[i], "#{path}[#{i}]", diffs, order) }
  elsif a != b || (a.is_a?(Float) && a.to_s != b.to_s)
    diffs << { "path" => path, "kind" => "value", "input" => show(a), "output" => show(b) }
  end
  [diffs, order]
end

# --- minimal draft-06 evaluator over the keywords the UnitsDB schemas use ---
EVALUATED = %w[$ref type required properties items enum const pattern minimum
               description title $schema $id definitions].freeze

def resolve(schema, node)
  while node.is_a?(Hash) && node["$ref"]
    ref = node["$ref"]
    raise "unsupported $ref #{ref}" unless ref.start_with?("#/")

    extra = node.reject { |k, _| k == "$ref" }
    node = ref.delete_prefix("#/").split("/").reduce(schema) { |s, k| s.fetch(k) }
    node = node.merge(extra.reject { |k, _| %w[description title].include?(k) }) unless extra.empty?
  end
  node
end

def type_ok?(type, v)
  Array(type).any? do |t|
    case t
    when "string" then v.is_a?(String)
    when "integer" then v.is_a?(Integer)
    when "number" then v.is_a?(Integer) || v.is_a?(Float)
    when "boolean" then v == true || v == false
    when "object" then v.is_a?(Hash)
    when "array" then v.is_a?(Array)
    when "null" then v.nil?
    else raise "unknown type #{t}"
    end
  end
end

def validate(schema, node, v, path, errs, skipped, undeclared)
  node = resolve(schema, node)
  return unless node.is_a?(Hash)

  (node.keys - EVALUATED).each { |k| skipped[k] = (skipped[k] || 0) + 1 }
  if node["type"] && !type_ok?(node["type"], v)
    errs << "#{path}: type #{v.class} not #{node['type']}"
    return
  end
  errs << "#{path}: #{show(v)} not in enum" if node["enum"] && !node["enum"].include?(v)
  errs << "#{path}: #{show(v)} != const" if node.key?("const") && node["const"] != v
  if node["pattern"] && v.is_a?(String) && v !~ Regexp.new(node["pattern"])
    errs << "#{path}: #{show(v)} !~ /#{node['pattern']}/"
  end
  if node["minimum"] && v.is_a?(Numeric) && v < node["minimum"]
    errs << "#{path}: #{v} < minimum #{node['minimum']}"
  end
  if v.is_a?(Hash)
    Array(node["required"]).each { |k| errs << "#{path}: missing required #{k}" unless v.key?(k) }
    props = node["properties"] || {}
    v.each do |k, sub|
      if props.key?(k)
        validate(schema, props[k], sub, "#{path}.#{k}", errs, skipped, undeclared)
      elsif node.key?("properties")
        # draft-06 allows it (no additionalProperties: false in these schemas)
        undeclared << "#{path}.#{k}"
      end
    end
  end
  return unless v.is_a?(Array) && node["items"]

  v.each_with_index { |sub, i| validate(schema, node["items"], sub, "#{path}[#{i}]", errs, skipped, undeclared) }
end

def record_id(rec, index)
  ids = rec.is_a?(Hash) ? Array(rec["identifiers"]) : []
  first = ids.find { |i| i.is_a?(Hash) && i["id"] }
  first ? first["id"].to_s : "index-#{index}"
end

def file_sha(path)
  Digest::SHA256.file(path).hexdigest
end

# ----------------------------------------------------------------- meta ---
data_files = Dir.glob("**/*.yaml", base: DATA_DIR).select do |p|
  p.start_with?("schemas/") || !p.include?("/")
end.sort
emit({
  "kind" => "meta", "id" => "#{PROFILE}/meta", "profile" => PROFILE,
  "ruby" => RUBY_DESCRIPTION,
  "gems" => %w[unitsdb unitsml lutaml-model canon].to_h { |g| [g, Gem.loaded_specs[g]&.version&.to_s] },
  "data_files" => data_files.to_h { |p| [p, file_sha(File.join(DATA_DIR, p))] },
})

# ------------------------------------------------------------- database ---
raws = {}
COLLECTIONS.each do |name, _, _|
  path = File.join(DATA_DIR, "#{name}.yaml")
  raws[name] = File.read(path, encoding: "UTF-8") if File.exist?(path)
end
parsed_raw = raws.transform_values { |s| YAML.safe_load(s) }

begin
  db_yaml = Unitsdb::Database.from_db(DATA_DIR).to_yaml
  combined = { "schema_version" => parsed_raw["prefixes"]["schema_version"] }
  COLLECTIONS.each { |name, _, _| combined[name] = parsed_raw[name][name] if parsed_raw[name] }
  db_out = YAML.safe_load(db_yaml)
  diffs, order = strict_diff(combined, db_out)
  canon = canon_verdict(combined.to_yaml, db_yaml)
  emit({
    "kind" => "database", "id" => "#{PROFILE}/database", "profile" => PROFILE,
    "call" => "Unitsdb::Database.from_db(dir).to_yaml",
    "collections" => combined.keys - ["schema_version"],
    "canon_equivalent" => canon, "strict_equal" => diffs.empty?, "strict_diffs" => diffs,
    "key_order_paths" => order.length,
    "canonical_json_sha256" => { "input" => canonical_sha(combined), "output" => canonical_sha(db_out) },
    "output_yaml_sha256" => Digest::SHA256.hexdigest(db_yaml),
    "outcome" => canon == true && diffs.empty? ? "pass" : "fail",
  })
rescue StandardError => e
  emit({ "kind" => "database", "id" => "#{PROFILE}/database", "profile" => PROFILE,
         "outcome" => "fail", "error" => "#{e.class}: #{e.message.lines.first.to_s.strip}" })
end

# ---------------------------------------------------------- collections ---
db_out_by_name = (db_out || {})

COLLECTIONS.each do |name, coll_cls, ent_cls|
  raw = raws[name]
  next unless raw

  schema_path = File.join(DATA_DIR, "schemas", "#{name}-schema.yaml")
  schema = YAML.safe_load_file(schema_path)
  header = raw.lines.first.start_with?("#") ? raw.lines.first.chomp : nil
  input = parsed_raw[name]
  klass = Unitsdb.const_defined?(coll_cls, false) ? Unitsdb.const_get(coll_cls, false) : nil
  out_yaml = nil
  out = nil
  error = nil
  if klass
    begin
      out_yaml = klass.from_yaml(raw).to_yaml
      out = YAML.safe_load(out_yaml)
    rescue StandardError => e
      error = "#{e.class}: #{e.message.lines.first.to_s.strip}"
    end
  end
  coll_row = {
    "kind" => "collection", "id" => "#{PROFILE}/collection/#{name}", "profile" => PROFILE,
    "collection" => name, "record_count" => Array(input[name]).length,
    "schema_id" => schema["$id"], "schema_header_comment" => header,
    "schema_version" => { "input" => input["schema_version"] },
  }
  if klass.nil?
    coll_row["call"] = nil
    coll_row["note"] = "unitsdb #{Gem.loaded_specs['unitsdb'].version} defines no Unitsdb::#{coll_cls} " \
                       "collection class; the collection roundtrips only through Unitsdb::Database " \
                       "(database row) and per record through Unitsdb::#{ent_cls}"
    out_list = db_out_by_name[name]
    coll_row["schema_version"]["output"] = db_out_by_name["schema_version"]
    coll_row["outcome"] = "not_applicable"
  elsif error
    coll_row["call"] = "Unitsdb::#{coll_cls}.from_yaml(raw).to_yaml"
    coll_row["error"] = error
    coll_row["outcome"] = "fail"
    out_list = nil
  else
    diffs, order = strict_diff(input, out)
    canon = canon_verdict(raw, out_yaml)
    errs_in = []
    errs_out = []
    skipped = {}
    und_in = []
    und_out = []
    validate(schema, schema, input, "$", errs_in, skipped, und_in)
    validate(schema, schema, out, "$", errs_out, skipped, und_out)
    new_errs = errs_out - errs_in
    coll_row.merge!(
      "call" => "Unitsdb::#{coll_cls}.from_yaml(raw).to_yaml",
      "schema_version" => { "input" => input["schema_version"], "output" => out["schema_version"],
                            "preserved" => input["schema_version"] == out["schema_version"] &&
                              input["schema_version"].class == out["schema_version"].class },
      "output_record_count" => Array(out[name]).length,
      "canon_equivalent" => canon, "strict_equal" => diffs.empty?, "strict_diffs" => diffs,
      "key_order_paths" => order.length,
      "schema_errors" => { "input" => errs_in.length, "output" => errs_out.length,
                           "output_only" => new_errs },
      "undeclared_key_paths" => { "input" => und_in.length, "output" => und_out.length },
      "schema_keywords_not_evaluated" => skipped.keys.sort,
      "schema_header_comment_in_output" => header ? out_yaml.include?(header) : nil,
      "canonical_json_sha256" => { "input" => canonical_sha(input), "output" => canonical_sha(out) },
      "input_yaml_sha256" => Digest::SHA256.hexdigest(raw),
      "output_yaml_sha256" => Digest::SHA256.hexdigest(out_yaml),
      "byte_identical_yaml" => raw == out_yaml,
    )
    coll_row["outcome"] = canon == true && diffs.empty? && new_errs.empty? &&
                          coll_row["schema_version"]["preserved"] ? "pass" : "fail"
    out_list = out[name]
  end

  # records
  item_schema = schema.dig("properties", name, "items")
  ent_klass = Unitsdb.const_get(ent_cls, false)
  seen = Hash.new(0)
  rec_rows = []
  Array(input[name]).each_with_index do |rec, i|
    rid = record_id(rec, i)
    seen[rid] += 1
    rid = "#{rid}#index-#{i}" if seen[rid] > 1
    row = { "kind" => "record", "id" => "#{PROFILE}/#{name}/#{rid}", "profile" => PROFILE,
            "collection" => name, "index" => i, "record_id" => rid,
            "identifiers" => Array(rec["identifiers"]).map { |x| "#{x['type']}:#{x['id']}" } }
    reasons = []
    # (a) record-level roundtrip through the entity class
    rec_yaml = rec.to_yaml
    begin
      gen = ent_klass.from_yaml(rec_yaml).to_yaml
      rec_out = YAML.safe_load(gen)
      canon = canon_verdict(rec_yaml, gen)
      diffs, order = strict_diff(rec, rec_out)
      row["entity"] = { "call" => "Unitsdb::#{ent_cls}.from_yaml(record.to_yaml).to_yaml",
                        "canon_equivalent" => canon, "strict_equal" => diffs.empty?,
                        "strict_diffs" => diffs, "key_order_paths" => order.length }
      reasons << "entity_canon" unless canon == true
      reasons << "entity_strict" unless diffs.empty?
    rescue StandardError => e
      rec_out = nil
      row["entity"] = { "error" => "#{e.class}: #{e.message.lines.first.to_s.strip}" }
      reasons << "entity_error"
    end
    # (b) the record inside the collection-level output
    coll_rec = out_list.is_a?(Array) ? out_list[i] : nil
    if out_list.is_a?(Array)
      cdiffs, = strict_diff(rec, coll_rec)
      row["in_collection_output"] = { "strict_equal" => cdiffs.empty?, "strict_diffs" => cdiffs }
      reasons << "collection_strict" unless cdiffs.empty?
    end
    # (c) provenance and schema-declared fields, by name
    declared = (resolve(schema, item_schema)["properties"] || {}).keys
    fields = {}
    (declared | PROVENANCE_FIELDS | rec.keys).each do |f|
      next unless rec.key?(f) || (rec_out.is_a?(Hash) && rec_out.key?(f)) || (coll_rec.is_a?(Hash) && coll_rec.key?(f))

      ok_e = rec_out.is_a?(Hash) && rec.key?(f) == rec_out.key?(f) && strict_diff(rec[f], rec_out[f])[0].empty?
      ok_c = coll_rec.is_a?(Hash) ? rec.key?(f) == coll_rec.key?(f) && strict_diff(rec[f], coll_rec[f])[0].empty? : nil
      fields[f] = { "declared" => declared.include?(f), "in_input" => rec.key?(f),
                    "entity_preserved" => ok_e, "collection_preserved" => ok_c }
      reasons << "field:#{f}" unless ok_e && ok_c != false
    end
    row["fields"] = fields
    errs_in = []
    errs_out = []
    skipped = {}
    und_in = []
    und_out = []
    validate(schema, item_schema, rec, "$", errs_in, skipped, und_in)
    validate(schema, item_schema, rec_out, "$", errs_out, skipped, und_out) if rec_out
    row["schema_errors"] = { "input" => errs_in, "entity_output_only" => errs_out - errs_in }
    row["undeclared_keys"] = { "input" => und_in, "entity_output_only" => und_out - und_in,
                               "dropped_by_entity" => rec_out ? und_in - und_out : nil }
    reasons << "schema_output" unless (errs_out - errs_in).empty?
    reasons << "undeclared_dropped" unless rec_out.nil? || (und_in - und_out).empty?
    row["failure_reasons"] = reasons.uniq
    row["outcome"] = reasons.empty? ? "pass" : "fail"
    rec_rows << row
  end
  coll_row["records"] = { "total" => rec_rows.length,
                          "pass" => rec_rows.count { |r| r["outcome"] == "pass" },
                          "fail" => rec_rows.count { |r| r["outcome"] == "fail" },
                          "failing_ids" => rec_rows.select { |r| r["outcome"] == "fail" }.map { |r| r["record_id"] },
                          "input_schema_error_ids" => rec_rows.reject { |r| r["schema_errors"]["input"].empty? }.map { |r| r["record_id"] },
                          "undeclared_key_paths" => rec_rows.flat_map { |r| r["undeclared_keys"]["input"].map { |k| k.sub(/\[\d+\]/, "[]") } }.tally.sort.to_h }
  emit(coll_row)
  rec_rows.each { |r| emit(r) }
end
