# frozen_string_literal: true

require_relative "fixed_field/segment"
require_relative "fixed_field/value"
require_relative "fixed_field/layout"
require_relative "fixed_field/view"
require_relative "fixed_field/marc21_layouts"
require_relative "exception"

module MARC
  class FixedField
    class LayoutMismatch < MARC::Exception
    end

    def self.layouts
      @layouts ||= [
        continuing_resource_layout,
        map_layout,
        book_layout,
        continuing_resource_006_layout,
        map_006_layout,
        book_006_layout
      ]
    end

    def self.register_layout(layout)
      layouts.delete_if { |existing| existing.id == layout.id }
      layouts.unshift(layout)
      layout
    end

    def self.unregister_layout(id)
      layout = layouts.find { |existing| existing.id == id }
      layouts.delete(layout) if layout
      layout
    end

    def self.layout(id)
      layouts.find { |layout| layout.id == id } || raise(KeyError, "unknown fixed-field layout #{id.inspect}")
    end

    def self.layout_for(record_or_leader, tag = "008", type_byte: nil)
      leader = record_or_leader.is_a?(MARC::Record) ? record_or_leader.leader : record_or_leader
      if type_byte.nil? && tag == "006" && record_or_leader.is_a?(MARC::Record) && record_or_leader[tag]
        type_byte = record_or_leader[tag].value[0]
      end
      layouts.find { |layout| layout.tag == tag && layout.matches_record?(leader, type_byte) } ||
        raise(LayoutMismatch, missing_layout_message(tag, leader))
    end

    def self.view(record_or_field, layout: nil, record: nil)
      if record_or_field.is_a?(MARC::Record)
        record = record_or_field
        field = record["008"]
        unless field
          field = MARC::ControlField.new("008", " " * 40)
          record.append(field)
        end
        selected = layout || layout_for(record, "008")
        assert_layout!(selected, record, "008")
        View.new(field, layout: selected)
      else
        field = record_or_field
        tag = field.tag
        type_byte = tag == "006" && field.value ? field.value[0] : nil
        selected = layout || layout_for(record, tag, type_byte: type_byte)
        assert_layout!(selected, record, tag, type_byte) if record && layout.nil?

        View.new(field, layout: selected)
      end
    end

    def self.migrate(record, layout:, rule: nil)
      target_layout = layout.is_a?(Layout) ? layout : self.layout(layout)
      current = view(record)
      original_leader = record.leader
      original_008 = record["008"] ? record["008"].value : nil
      migrated = current.migrate(target_layout, rule: rule)
      error = migrated.errors.find { |message| blocking_validation_message?(message) }
      if error
        record["008"].value = original_008 if original_008
        record.leader = original_leader
        raise ValidationError, [error]
      end

      record.leader = (original_leader || " " * 24).dup
      record.leader[6] = target_layout.record_types.first[:record_type]
      levels = target_layout.record_types.map { |candidate| candidate[:bibliographic_level] }
      record.leader[7] = levels.compact.first || "m"
      migrated
    end

    def self.assert_layout!(layout, record, tag, type_byte = nil)
      return if layout.matches_record?(record, type_byte)

      message = "layout #{layout.id.inspect} does not match #{tag}; migrate with an explicit rule first"
      raise LayoutMismatch, message
    end

    def self.missing_layout_message(tag, leader)
      record_type = leader && leader[6]
      bibliographic_level = leader && leader[7]
      "no fixed-field layout matches tag #{tag.inspect}, leader[6]=#{record_type.inspect}, leader[7]=#{bibliographic_level.inspect}"
    end

    def self.blocking_validation_message?(message)
      prefixes = [
        "unknown code",
        "must be ",
        "date type is blank",
        "date1 must",
        "date2 must",
        "date range is inconsistent"
      ]
      prefixes.any? { |prefix| message.start_with?(prefix) }
    end
  end
end
