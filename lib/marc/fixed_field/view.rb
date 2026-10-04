# frozen_string_literal: true

module MARC
  module FixedField
    class View
      attr_reader :record, :tag, :layout

      def initialize(record, tag = "008", explicit_layout: nil)
        @record = record
        @tag = tag
        @explicit = !explicit_layout.nil?
        @layout =
          if explicit_layout.is_a?(Layout)
            explicit_layout
          elsif explicit_layout
            FixedField.layout(explicit_layout)
          else
            FixedField.layout_for_record(record)
          end

        if record.pending_fixed_field_migration?
          raise PendingMigration,
            "record type changed; choose an explicit 008 migration rule with Record#migrate_fixed_field"
        end
        if @explicit && !@layout.matches_record?(record)
          raise LayoutMismatch,
            "layout #{@layout.key.inspect} does not match leader record type or bibliographic level"
        end
        cached_layout = record.instance_variable_get(:@fixed_field_layout_key)
        if !@explicit && cached_layout && cached_layout != @layout.canonical_key
          record.instance_variable_set(:@pending_fixed_field_migration, true)
          raise PendingMigration,
            "record type changed; choose an explicit 008 migration rule with Record#migrate_fixed_field"
        end
        unless @explicit
          record.instance_variable_set(:@fixed_field_layout_key, @layout.canonical_key)
        end
      end

      def self.new_for_migration(record, tag, layout)
        view = allocate
        view.instance_variable_set(:@record, record)
        view.instance_variable_set(:@tag, tag)
        view.instance_variable_set(:@layout, layout)
        view.instance_variable_set(:@explicit, true)
        view
      end

      def field
        @record.fields(tag).first ||
          raise(FieldNotFound, "record does not contain control field #{tag.inspect}")
      end

      def raw
        field.value.to_s
      end

      def [](name)
        value_at(position(name))
      end

      def []=(name, value)
        set(name, value)
      end

      def fetch(name)
        position = position(name)
        value = value_at(position)
        {
          name: position.name,
          label: position.label,
          value: value,
          code_label: position.code_label(value),
          offset: position.offset,
          width: position.width,
          state: state_for(position, value)
        }
      end

      def set(name, value)
        ensure_current_layout
        position = position(name)
        candidate = raw.dup
        value = normalize_value(position, value)
        candidate[position.range] = value
        validate_candidate(candidate, [position.name])
        field.value = candidate
        value
      end

      def update(values)
        ensure_current_layout
        candidate = raw.dup
        touched = values.map do |name, value|
          position = position(name)
          candidate[position.range] = normalize_value(position, value)
          position.name
        end
        validate_candidate(candidate, touched)
        field.value = candidate
        self
      end

      def valid?
        errors.none?
      end

      def validate!
        messages = errors
        raise ValidationError, messages if messages.any?
        true
      end

      def errors(value = raw)
        messages = []
        if value.length != layout.length
          messages << "#{tag} must be #{layout.length} characters, got #{value.length}"
          return messages
        end

        layout.positions.each do |position|
          messages.concat(position_errors(position, value[position.range]))
        end
        messages.concat(linked_errors(value))
        messages
      end

      def to_h
        layout.positions.each_with_object({}) do |position, result|
          result[position.name] = value_at(position)
        end
      end

      def details
        layout.positions.map do |position|
          value = value_at(position)
          {
            name: position.name,
            label: position.label,
            aliases: position.aliases,
            value: value,
            code_label: position.code_label(value),
            offset: position.offset,
            range: position.range,
            width: position.width,
            state: state_for(position, value)
          }
        end
      end

      def position(name)
        layout.position(name) ||
          raise(ArgumentError, "unknown fixed-field position #{name.inspect} for layout #{layout.key.inspect}")
      end

      def range_for(name)
        position(name).range
      end
      alias offset_for range_for

      def offset_of(name)
        position(name).offset
      end

      alias_method :offset_for, :offset_of

      def position_at(offset)
        layout.position_at(offset)
      end

      def name_at(offset)
        position = position_at(offset)
        position&.name
      end

      private

      def ensure_current_layout
        return if @explicit && layout.matches_record?(record)

        current = FixedField.layout_for_record(record)
        return if current.canonical_key == layout.canonical_key

        record.instance_variable_set(:@pending_fixed_field_migration, true)
        raise PendingMigration,
          "record type changed; choose an explicit 008 migration rule with Record#migrate_fixed_field"
      end

      def value_at(position)
        value = raw[position.range]
        return " " * position.width if value.nil?
        value.ljust(position.width, " ")
      end

      def normalize_value(position, value)
        value = " " * position.width if value.nil?
        value = value.to_s
        if value.length != position.width
          raise ValidationError,
            "#{position.label} is #{position.width} character(s), got #{value.length}"
        end
        value
      end

      def validate_candidate(candidate, touched)
        messages = edit_errors(candidate, touched)
        if messages.any?
          raise ValidationError, messages
        end
        candidate
      end

      def edit_errors(value, touched)
        messages = []
        if value.length != layout.length
          messages << "#{tag} must be #{layout.length} characters, got #{value.length}"
          return messages
        end

        layout.positions.each do |position|
          next unless touched.include?(position.name)
          messages.concat(position_errors(position, value[position.range]))
        end
        messages.concat(linked_errors(value))
        messages
      end

      def position_errors(position, value)
        return ["#{position.label} is missing"] if value.nil?

        messages = []
        if position.codes.any?
          values = position.repeatable ? value.chars : [value]
          values.each do |character|
            next if character == BLANK_CHARACTER || character == FILL_CHARACTER
            unless position.codes.key?(character)
              messages << "#{position.label} has unknown encoding #{character.inspect}"
            end
          end
        elsif position.pattern && !(position.pattern === value)
          messages << "#{position.label} is invalid (#{value.inspect})"
        end
        messages
      end

      def linked_errors(value)
        values = layout.positions.each_with_object({}) do |position, result|
          result[position.name] = value[position.range].to_s.ljust(position.width, " ")
        end
        layout.linked_validators.flat_map do |names, validator|
          selected = names.map { |name| values[name] }
          Array(validator.call(*selected, values)).reject(&:nil?)
        end
      end

      def state_for(position, value)
        if value == BLANK_CHARACTER * position.width
          :blank
        elsif value == FILL_CHARACTER * position.width
          :fill_character
        elsif coded_state?(position, value)
          :known
        elsif position.pattern && (position.pattern === value)
          :known
        else
          :unknown_encoding
        end
      end

      def coded_state?(position, value)
        values = position.repeatable ? value.chars : [value]
        values.all? do |item|
          item == BLANK_CHARACTER || item == FILL_CHARACTER || position.codes.key?(item)
        end
      end
    end
  end
end
