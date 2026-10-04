# frozen_string_literal: true

module MARC
  # A read-oriented view of fields connected by repeated subfield $8 values.
  class LinkGroupView
    include Enumerable

    LINK_VALUE_PATTERN = Regexp.new(
      "\\A(?<link_number>\\d{1,3})" \
      "(?:(?<separator>[-.])(?<sequence_number>\\d{1,2}))?" \
      "(?:\\\\(?<link_type>[a-z]))?\\z"
    )

    Issue = Struct.new(:code, :message, :link_number, :field_position, :subfield_position, :details)
    Change = Struct.new(:field_position, :subfield_position, :from, :to)

    def self.parse_link_value(value)
      match = LINK_VALUE_PATTERN.match(value.to_s)
      return unless match

      {
        link_number: match[:link_number].to_i,
        sequence_number: match[:sequence_number] && match[:sequence_number].to_i,
        link_type: match[:link_type],
        separator: match[:separator]
      }
    end

    def initialize(record)
      @record = record
      @members = []
      @issues = []
      @connected_field_positions = {}
      parse_record
      @groups = build_groups
    end

    def each(&block)
      @groups.each(&block)
    end

    def groups
      @groups.dup
    end

    def [](link_number)
      group(link_number)
    end

    def group(link_number)
      id = canonical_link_number(link_number)
      @groups.find { |group| group.link_number == id }
    end

    def unlinked_fields
      @record.fields.select.with_index do |_field, position|
        !@connected_field_positions.key?(position)
      end
    end

    def issues
      @issues.dup
    end

    def plan_reorder(link_number, ordered_fields)
      group = find_group!(link_number)
      ordered_members = []
      errors = []
      seen_positions = {}

      Array(ordered_fields).each do |item|
        member = resolve_member(group, item)
        if member.nil?
          errors << plan_error(
            :outside_member,
            "order contains field #{field_reference(item)} that is not in link group #{group.link_number}"
          )
          next
        end

        if seen_positions.key?(member.field_position)
          errors << plan_error(
            :duplicate_order_member,
            "field position #{member.field_position} appears more than once in the order"
          )
        end
        seen_positions[member.field_position] = member
        ordered_members << member
      end

      ordered_positions = ordered_members.map(&:field_position)
      sequenced_positions = group.members.select(&:sequence_number?).map(&:field_position)
      required_positions =
        if sequenced_positions.empty?
          group.members.map(&:field_position)
        else
          sequenced_positions
        end

      if (required_positions - ordered_positions).any?
        errors << plan_error(
          :incomplete_order,
          "order must include all sequenced members of link group #{group.link_number}"
        )
      end

      changes = ordered_members.each_with_index.flat_map do |member, index|
        sequence_number = index + 1
        next [] if member.sequence_number == sequence_number

        separator = member.separator || "-"
        suffix = member.link_type ? "\\#{member.link_type}" : ""
        new_value = "#{group.link_number}#{separator}#{sequence_number}#{suffix}"
        next [] if new_value == member.raw_value

        [Change.new(member.field_position, member.subfield_position, member.raw_value, new_value)]
      end

      errors.concat(blocking_issues([group]))
      LinkGroupPlan.new(@record, :reorder, group.link_number, changes, errors, @issues)
    end

    def plan_renumber(mapping)
      raise ArgumentError, "renumber mapping cannot be empty" if mapping.empty?

      source_groups = []
      targets = {}
      errors = []

      mapping.each do |old_link_number, new_link_number|
        group = group(old_link_number)
        unless group
          errors << plan_error(:unknown_link_group, "unknown link group #{old_link_number.inspect}")
          next
        end

        target = canonical_link_number(new_link_number)
        unless target && new_link_number.to_s.match?(/\A\d{1,3}\z/)
          errors << plan_error(
            :invalid_link_number,
            "new link number #{new_link_number.inspect} must be a 1-3 digit number"
          )
        end

        source_groups << group
        targets[group.link_number] = target
      end

      if errors.empty?
        final_link_numbers = @groups.map { |group| targets.fetch(group.link_number, group.link_number) }
        duplicate_targets = final_link_numbers.group_by(&:itself).select { |_id, ids| ids.length > 1 }
        duplicate_targets.each_key do |id|
          errors << plan_error(:duplicate_link_number, "link number #{id} would be duplicated")
        end
      end

      changes =
        if errors.empty?
          source_groups.flat_map do |group|
            group.members.map do |member|
              new_value = member.raw_value.sub(/\A\d+/, targets[group.link_number].to_s)
              next if new_value == member.raw_value

              Change.new(member.field_position, member.subfield_position, member.raw_value, new_value)
            end
          end.compact
        else
          []
        end

      errors.concat(blocking_issues(source_groups))
      LinkGroupPlan.new(@record, :renumber, nil, changes, errors, @issues)
    end

    private

    def parse_record
      @record.fields.each_with_index do |field, field_position|
        next unless field.is_a?(MARC::DataField)

        declared_links = {}
        field.subfields.each_with_index do |subfield, subfield_position|
          next unless subfield.code == "8"

          parsed = self.class.parse_link_value(subfield.value)
          unless parsed
            add_issue(
              :invalid_link_value,
              "invalid $8 value #{subfield.value.inspect}",
              nil, field_position, subfield_position, value: subfield.value
            )
            next
          end

          if declared_links.key?(parsed[:link_number])
            add_issue(
              :duplicate_link_declaration,
              "field #{field_position} declares link group #{parsed[:link_number]} more than once",
              parsed[:link_number], field_position, subfield_position, value: subfield.value
            )
            next
          end

          declared_links[parsed[:link_number]] = true
          @connected_field_positions[field_position] = true
          @members << LinkGroup::Member.new(
            field, field_position, subfield_position, subfield.value,
            parsed[:link_number], parsed[:sequence_number], parsed[:separator], parsed[:link_type]
          )
        end
      end
    end

    def build_groups
      @members.group_by(&:link_number).sort_by(&:first).map do |link_number, members|
        ordered = members.sort_by { |member| [member.field_position, member.subfield_position] }
        group = LinkGroup.new(link_number, ordered)
        add_sequence_issues(group)
        add_link_type_issues(group)
        group
      end
    end

    def add_sequence_issues(group)
      sequenced_members = group.members.select(&:sequence_number?)
      return if sequenced_members.empty?

      numbers = sequenced_members.group_by(&:sequence_number)
      numbers.each do |sequence_number, members|
        next unless members.length > 1

        members.each do |member|
          add_issue(
            :duplicate_sequence_number,
            "link group #{group.link_number} has duplicate sequence number #{sequence_number}",
            group.link_number, member.field_position, member.subfield_position,
            sequence_number: sequence_number
          )
        end
      end

      present = numbers.keys.sort
      expected = (present.first..present.last).to_a
      (expected - present).each do |missing|
        add_issue(
          :missing_sequence_number,
          "link group #{group.link_number} is missing sequence number #{missing}",
          group.link_number, nil, nil, sequence_number: missing
        )
      end
    end

    def add_link_type_issues(group)
      seen_types = []
      group.members.each do |member|
        next if member.link_type.nil?
        next if seen_types.include?(member.link_type)

        unless seen_types.empty?
          add_issue(
            :inconsistent_link_type,
            "link group #{group.link_number} has inconsistent link types #{group.link_types.sort.join(", ")}",
            group.link_number, member.field_position, member.subfield_position,
            expected_link_type: seen_types.first, actual_link_type: member.link_type
          )
        end
        seen_types << member.link_type
      end
    end

    def add_issue(code, message, link_number, field_position, subfield_position, details = {})
      @issues << Issue.new(code, message, link_number, field_position, subfield_position, details)
    end

    def blocking_issues(groups)
      affected_positions = groups.flat_map { |group| group.members.map(&:field_position) }.to_set
      @issues.select do |issue|
        issue.code == :duplicate_link_declaration && affected_positions.include?(issue.field_position)
      end
    end

    def plan_error(code, message)
      {code: code, message: message, details: {}}
    end

    def find_group!(link_number)
      group(link_number) || raise(ArgumentError, "unknown link group #{link_number.inspect}")
    end

    def resolve_member(group, item)
      case item
      when LinkGroup::Member
        group.members.find do |member|
          member.field_position == item.field_position && member.subfield_position == item.subfield_position
        end
      when MARC::DataField
        group.members.find { |member| member.field.equal?(item) }
      when Integer
        group.members.find { |member| member.field_position == item }
      end
    end

    def field_reference(item)
      item.is_a?(Integer) ? "position #{item}" : item.inspect
    end

    def canonical_link_number(value)
      return value if value.is_a?(Integer)
      value.to_s.to_i if value.to_s.match?(/\A\d{1,3}\z/)
    end
  end

  class LinkGroup
    class Member
      attr_reader :field, :field_position, :subfield_position, :raw_value, :link_number,
        :sequence_number, :separator, :link_type

      def initialize(
        field, field_position, subfield_position, raw_value,
        link_number, sequence_number, separator, link_type
      )
        @field = field
        @field_position = field_position
        @subfield_position = subfield_position
        @raw_value = raw_value
        @link_number = link_number
        @sequence_number = sequence_number
        @separator = separator
        @link_type = link_type
      end

      def sequence_number?
        !@sequence_number.nil?
      end
    end

  attr_reader :link_number, :members

  def initialize(link_number, members)
    @link_number = link_number
    @members = members
  end

  def ordered_members
    @members.sort_by do |member|
      [member.sequence_number ? 0 : 1, member.sequence_number || 0, member.field_position, member.subfield_position]
    end
  end

  def sequence_numbers
    @members.map(&:sequence_number)
  end

  def field_positions
    @members.map(&:field_position)
  end

  def link_types
    @members.map(&:link_type).compact.uniq.sort
  end

  def link_type
    types = link_types
    types.first if types.length == 1
  end
  end

  class LinkGroupPlan
    attr_reader :operation, :link_number, :changes, :errors, :source_issues

    def initialize(record, operation, link_number, changes, errors, source_issues)
      @record = record
      @operation = operation
      @link_number = link_number
      @changes = changes
      @errors = errors
      @source_issues = source_issues
    end

    def valid?
      @errors.empty?
    end

    def apply(record = nil)
      unless valid?
        raise MARC::Exception, "cannot apply invalid link group plan: #{@errors.join("; ")}"
      end

      target = record || deep_dup_record(@record)
      @changes.each do |change|
        field = target.fields[change.field_position]
        subfield = field&.subfields&.[](change.subfield_position)
        unless subfield
          raise MARC::Exception, "change target field or subfield no longer exists"
        end

        subfield.value = change.to
      end
      target
    end

    def to_h
      {
        operation: @operation,
        link_number: @link_number,
        valid: valid?,
        errors: @errors.map(&:to_h),
        source_issues: @source_issues.map(&:to_h),
        changes: @changes.map { |change| change.to_h }
      }
    end

    private

    def deep_dup_record(record)
      copy = MARC::Record.new
      copy.leader = record.leader.dup
      record.each { |field| copy.append(deep_dup_field(field)) }
      copy
    end

    def deep_dup_field(field)
      case field
      when MARC::ControlField
        MARC::ControlField.new(field.tag.dup, field.value.dup)
      when MARC::DataField
        subfields = field.subfields.map do |subfield|
          MARC::Subfield.new(subfield.code.dup, subfield.value.dup)
        end
        MARC::DataField.new(field.tag.dup, field.indicator1.dup, field.indicator2.dup, *subfields)
      end
    end
  end
end
