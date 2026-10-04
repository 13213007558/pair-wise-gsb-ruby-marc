#!/usr/bin/env ruby

# Work with original/alternate-script field pairs ($6 / 880) as groups.

require "marc"

record = MARC::Record.new

# Two 245 fields, each with its own alternate-script 880.  The library
# writes the matching $6 subfields and picks occurrence numbers.
record.append_field_link(
  MARC::DataField.new("245", "1", "0", ["a", "First title"]),
  MARC::DataField.new("880", "1", "0", ["a", "第一标题"]),
  script: "$1"
)
record.append_field_link(
  MARC::DataField.new("245", "1", "0", ["a", "Second title"]),
  MARC::DataField.new("880", "1", "0", ["a", "第二标题"]),
  script: "$1"
)

# Read the relationships back as groups, not by matching tags blindly.
record.each_field_link_group do |group|
  original = group.field && group.field["a"]
  alternate = group.alternate && group.alternate["a"]
  puts format("%s-%02d %p <=> %p", group.tag, group.occurrence, original, alternate)
end

# Remove one whole group and insert a replacement.  The surviving pair's
# links still point at each other.
record.delete_field_link("245", 2)
record.append_field_link(
  MARC::DataField.new("245", "1", "0", ["a", "Replacement title"]),
  MARC::DataField.new("880", "1", "0", ["a", "替换标题"]),
  script: "$1"
)

# Compact occurrence numbers per original tag if gaps have accumulated.
record.renumber_field_links

puts record
