# frozen_string_literal: true

require_relative "fixed_field/position"
require_relative "fixed_field/layout"
require_relative "fixed_field/view"
require_relative "fixed_field/marc21"
require_relative "exception"

module MARC
  # Semantic view over position-based MARC control fields such as the 008.
  module FixedField
    LENGTH_008 = 40
    FILL_CHARACTER = "|"
    BLANK_CHARACTER = " "

    class Error < MARC::Exception; end
    class LayoutNotFound < Error; end
    class FieldNotFound < Error; end
    class LayoutMismatch < Error; end
    class PendingMigration < Error; end
    class ValidationError < Error
      attr_reader :errors

      def initialize(errors)
        @errors = Array(errors)
        super(@errors.join("; "))
      end
    end

    @layouts = {}

    class << self
      def register_layout(layout)
        unless layout.is_a?(Layout)
          raise ArgumentError, "expected MARC::FixedField::Layout, got #{layout.class}"
        end
        ([layout.key] + layout.aliases).each do |key|
          @layouts[key.to_s] = layout
        end
        layout
      end

      def layout(key)
        @layouts.fetch(key.to_s) do
          raise LayoutNotFound, "unknown fixed-field layout #{key.inspect}"
        end
      end

      def layouts
        @layouts.dup
      end

      def declare(key, **options, &block)
        register_layout(Layout.define(key, **options, &block))
      end

      def for(record, tag = "008", layout: nil)
        View.new(record, explicit_layout: layout)
      end

      def migrate(record, **options, &block)
        to = options.fetch(:to)
        rule = options[:rule]
        tag = options[:tag] || "008"
        raw_source = record.fields(tag).first&.value
        source = begin
          self.for(record, tag)
        rescue FieldNotFound, LayoutNotFound, PendingMigration
          nil
        end
        target = layout(to)
        rule = block if block
        raise ArgumentError, "a migration rule is required" if rule.nil?

        source = source_for_migration(record, tag, target, raw_source) if source.nil? && raw_source

        value =
          case rule
          when :blank
            BLANK_CHARACTER * LENGTH_008
          when :preserve_common
            preserve_common(source)
          when Proc
            rule.call(source, target, record)
          else
            raise ArgumentError, "unknown migration rule #{rule.inspect}"
          end

        value = value.to_s
        unless value.length == LENGTH_008
          raise ValidationError, "migrated 008 value must be #{LENGTH_008} characters"
        end
        candidate = View.new_for_migration(record, tag, target)
        messages = candidate.errors(value)
        raise ValidationError, messages if messages.any?

        field = record.fields(tag).first
        if field
          field.value = value.dup
        else
          record << ControlField.new(tag, value.dup)
        end

        record.leader = " " * 24 if record.leader.nil? || record.leader.length < 7
        record.leader = record.leader.ljust(7, BLANK_CHARACTER)
        record.leader[6] = target.default_record_type
        record.leader[7] = target.default_bibliographic_level
        record.instance_variable_set(:@fixed_field_layout_key, target.canonical_key)
        record.instance_variable_set(:@previous_fixed_field_layout_key, nil)
        record.instance_variable_set(:@pending_fixed_field_migration, false)
        View.new(record, tag, explicit_layout: target.key)
      end

      def source_for_migration(record, tag, target, raw)
        layout_key = record.instance_variable_get(:@previous_fixed_field_layout_key)
        return nil unless layout_key
        View.new_for_migration(record, tag, layout(layout_key))
      rescue FieldNotFound, LayoutMismatch, PendingMigration
        nil
      end

      def layout_for_record(record)
        leader = record.leader.to_s
        record_type = leader.length > 6 ? leader[6] : nil
        bibliographic_level = leader.length > 7 ? leader[7] : nil

        if %w[a t].include?(record_type) && %w[b s i].include?(bibliographic_level)
          layout(:serial)
        elsif %w[a t].include?(record_type)
          layout(:book)
        elsif %w[e f].include?(record_type)
          layout(:map)
        else
          raise LayoutNotFound,
            "no built-in fixed-field layout for record type #{record_type.inspect}"
        end
      end

      private

      def preserve_common(source)
        value = BLANK_CHARACTER * LENGTH_008
        return value unless source

        raw = source.raw.ljust(LENGTH_008, BLANK_CHARACTER)
        [(0..5), (7..17), (35..39)].each do |range|
          value[range] = raw[range]
        end
        value
      end
    end

    MARC21.declare
  end

  class Record
    def fixed_field(tag = "008", layout: nil)
      MARC::FixedField.for(self, tag, layout: layout)
    end

    def migrate_fixed_field(**options, &block)
      MARC::FixedField.migrate(self, **options, &block)
    end

    def leader=(leader)
      old_key = layout_key_for_leader(@leader)
      @leader = leader
      new_key = layout_key_for_leader(@leader)

      @fixed_field_layout_key = new_key
      if old_key && (new_key.nil? || old_key != new_key)
        @pending_fixed_field_migration = true
        @previous_fixed_field_layout_key = old_key
      end
      @leader
    end

    def pending_fixed_field_migration?
      !!@pending_fixed_field_migration
    end

    private

    def layout_key_for_leader(leader)
      temporary = MARC::Record.allocate
      temporary.instance_variable_set(:@leader, leader)
      MARC::FixedField.layout_for_record(temporary).canonical_key
    rescue FixedField::Error
      nil
    end
  end
end
