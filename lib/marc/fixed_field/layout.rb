# frozen_string_literal: true

module MARC
  module FixedField
    class Layout
      attr_reader :key, :label, :aliases, :positions, :record_types,
        :bibliographic_levels, :default_record_type, :default_bibliographic_level,
        :linked_validators

      def initialize(key, label: nil, aliases: [], record_types: [],
        bibliographic_levels: nil, default_record_type: " ",
        default_bibliographic_level: " ", length: LENGTH_008)
        @key = key.to_sym
        @label = label || key.to_s
        @aliases = Array(aliases).map(&:to_s)
        @record_types = Array(record_types)
        @bibliographic_levels = bibliographic_levels
        @default_record_type = default_record_type
        @default_bibliographic_level = default_bibliographic_level
        @length = Integer(length)
        @positions = []
        @linked_validators = []
      end

      def self.define(key, **options, &block)
        layout = new(key, **options)
        DefinitionContext.new(layout, block.binding.receiver).instance_exec(layout, &block)
        layout.validate!
        layout
      end

      def field(name, offset, width, **options)
        @positions << Position.new(name, offset, width, **options)
      end

      def gap(name, offset, width = 1)
        field(name, offset, width, label: "未使用位段", aliases: ["保留位段"])
      end

      def linked_validator(*names, &block)
        @linked_validators << [names.flatten, block]
      end

      def canonical_key
        key
      end

      def length
        @length
      end

      def position(name)
        @positions.find { |position| position.name == resolve_name(name) }
      end

      def position_at(offset)
        @positions.find { |position| position.include?(offset) }
      end

      def range_for(name)
        position(name).range
      end

      def offset_for(name)
        range = range_for(name)
        range.size == 1 ? range.begin : range
      end

      def matches_record?(record)
        leader = record.leader.to_s
        return false if leader.length < 7
        return false unless record_types.include?(leader[6])
        bibliographic_levels.nil? || bibliographic_levels.include?(leader[7])
      end

      def validate!
        sorted = @positions.sort_by(&:offset)
        unless sorted.first && sorted.first.offset == 0
          raise Error, "layout #{key} must begin at character offset 0"
        end

        sorted.each_cons(2) do |left, right|
          next if left.offset + left.width == right.offset
          raise Error, "layout #{key} has a gap or overlap between #{left.name} and #{right.name}"
        end

        last = sorted.last
        unless last.offset + last.width == @length
          raise Error, "layout #{key} must be exactly #{@length} characters"
        end
        true
      end

      private

      def resolve_name(name)
        name = name.to_s
        found = @positions.find do |position|
          position.lookup_names.include?(name)
        end
        found&.name || name.to_sym
      end
    end

    class DefinitionContext
      def initialize(layout, helper_context)
        @layout = layout
        @helper_context = helper_context
      end

      def field(*arguments, **options)
        @layout.field(*arguments, **options)
      end

      def gap(name, offset, width = 1, **options)
        @layout.gap(name, offset, width, **options)
      end

      def linked_validator(*arguments, &block)
        @layout.linked_validator(*arguments, &block)
      end

      def method_missing(name, *arguments, &block)
        if @helper_context.respond_to?(name, true)
          if arguments.empty?
            @helper_context.send(name, @layout, &block)
          else
            @helper_context.send(name, *arguments, &block)
          end
        else
          super
        end
      end

      def respond_to_missing?(name, include_private = false)
        @helper_context.respond_to?(name, include_private) || super
      end
    end
  end
end
