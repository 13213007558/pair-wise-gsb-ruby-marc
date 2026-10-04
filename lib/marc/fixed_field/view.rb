# frozen_string_literal: true

module MARC
  class FixedField
    class ValidationError < MARC::Exception
      attr_reader :errors

      def initialize(errors)
        @errors = errors
        super(errors.join("; "))
      end
    end

    class View
      attr_reader :field, :layout, :offset_base

      def initialize(field, layout:, offset_base: 0)
        @field = field
        @layout = layout
        @offset_base = offset_base
      end

      def [](name)
        segment = layout.segment_for(name)
        Value.new(segment, projected_value[local_offset(segment), segment.length] || +"")
      end

      def []=(name, value)
        update(name => value)
      end

      def update(values)
        original = field.value
        candidate = projected_value.dup
        begin
          values.each do |name, value|
            segment = layout.segment_for(name)
            value = normalize_value(segment, value.to_s)
            validate_width(segment, value)
            validate_enum(segment, value)
            candidate[local_offset(segment), segment.length] = value
          end

          validate_links(candidate)
          write_projected(candidate)
          self
        rescue StandardError
          field.value = original
          raise
        end
      end

      def fetch(name)
        self[name].raw
      end

      def offset_of(name)
        offset_base + layout.offset_of(name)
      end

      def name_at(offset)
        layout.segment_for(offset - offset_base).name
      end

      def segment_at(offset)
        layout.segment_for(offset - offset_base)
      end

      def errors
        candidate = projected_value
        messages = []
        value = field.value || +""
        unless value.length >= required_field_length
          messages << "#{layout.tag} must be at least #{required_field_length} characters, got #{value.length}"
        end
        layout.segments.each do |segment|
          value = candidate[local_offset(segment), segment.length] || +""
          messages << width_message(segment, value) unless value.length == segment.length
          next unless value.length == segment.length

          validate_enum_message(segment, value, messages)
        end
        validate_links(candidate, messages)
        messages
      end

      def valid?
        errors.none?
      end

      def apply!
        write_projected(projected_value)
        field
      end

      def migrate(target_layout, rule: nil)
        allowed_rules = %i[preserve_common reset_semantic_segments reset_all]
        unless allowed_rules.include?(rule)
          raise ArgumentError, "migration requires one of #{allowed_rules.map(&:inspect).join(", ")}"
        end

        target_view =
          if target_layout.tag == layout.tag
            View.new(field, layout: target_layout, offset_base: offset_base)
          else
            raise ArgumentError, "cannot migrate fixed field tag #{layout.tag} to #{target_layout.tag}"
          end

        target = +(" " * target_layout.field_length)
        case rule
        when :preserve_common then preserve_common_segments(target, target_layout)
        when :reset_semantic_segments
          copy_common_prefix(target)
          copy_common_suffix(target)
        when :reset_all then nil
        else
          raise ArgumentError, "unknown migration rule #{rule.inspect}"
        end

        original = field.value
        begin
          target_view.write_projected(target)
          target_view
        rescue StandardError
          field.value = original
          raise
        end
      end

      protected

      def write_projected(value)
        raw = padded_field_value.dup
        raw[offset_base, layout.field_length] = normalized_field(value)
        field.value = raw
      end

      def projected_value
        padded_field_value[offset_base, layout.field_length] || +""
      end

      def local_offset(segment)
        segment.offset - offset_base
      end

      def padded_field_value
        (field.value || +"").ljust(required_field_length, " ")
      end

      def required_field_length
        offset_base + layout.field_length
      end

      def normalized_field(value)
        value.ljust(layout.field_length, " ")[0, layout.field_length]
      end

      def normalize_value(segment, value)
        return value if value.length >= segment.length
        value.ljust(segment.length, " ")
      end

      def validate_width(segment, value)
        return if value.length == segment.length

        raise ValidationError, [width_message(segment, value)]
      end

      def width_message(segment, value)
        "#{segment.name} must be #{segment.length} characters, got #{value.length}"
      end

      def validate_enum(segment, value)
        errors = []
        validate_enum_message(segment, value, errors)
        raise ValidationError, errors if errors.any?
      end

      def validate_enum_message(segment, value, messages)
        return unless segment.coded?
        return if segment.valid_value?(value)

        characters = segment.repeatable ? value.chars : [value]
        characters.each_with_index do |character, index|
          next if segment.values.key?(character)

          position = local_offset(segment) + index
          message = "unknown code #{character.inspect} at #{segment.name} offset #{position}"
          messages << message
        end
      end

      def validate_links(value, messages = nil)
        return if offset_base != 0 || layout.field_length != 40

        date_type = value[6, 1]
        date1 = value[7, 4] || +""
        date2 = value[11, 4] || +""
        date_errors = date_errors(date_type, date1, date2)
        if messages
          messages.concat(date_errors)
        elsif date_errors.any?
          raise ValidationError, date_errors
        end
      end

      def date_errors(date_type, date1, date2)
        messages = []
        return messages unless layout[:date_type]

        if date_type.strip.empty?
          messages << "date type is blank"
          return messages
        end

        unless valid_date?(date1)
          messages << "date1 must contain four digits, blank, or fill characters"
        end
        unless valid_date?(date2)
          messages << "date2 must contain four digits, blank, or fill characters"
        end
        if %w[e i k m q r t].include?(date_type)
          if !(numeric_date?(date1) && numeric_date?(date2))
            messages << "date type #{date_type.inspect} requires numeric date1 and date2"
          elsif date1 > date2
            messages << "date range is inconsistent: date1 #{date1} is later than date2 #{date2}"
          end
        end
        messages
      end

      def valid_date?(value)
        value =~ /\A(?:\d{4}| {4}|\|{4})\z/
      end

      def numeric_date?(date)
        date =~ /\A\d{4}\z/
      end

      def copy_common_prefix(target)
        length = [projected_value.length, 18, target.length].min
        target[0, length] = projected_value[0, length]
      end

      def copy_common_suffix(target)
        source = projected_value
        [[35, 5], [38, 1], [39, 1]].each do |offset, length|
          next if source.length < offset + length || target.length < offset + length

          target[offset, length] = source[offset, length]
        end
      end

      def preserve_common_segments(target, target_layout)
        layout.segments.each do |segment|
          target_segment = target_layout[segment.name]
          next unless target_segment
          next unless target_segment.length == segment.length

          value = projected_value[local_offset(segment), segment.length]
          target[target_segment.offset, target_segment.length] = value
        end
      end
    end

    View::ValidationError = ValidationError
  end
end
