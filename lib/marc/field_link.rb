# frozen_string_literal: true

module MARC
  # A MARC field link carried in subfield $6. Links connect a field with
  # its alternate-script representation (always tagged 880) and can also
  # connect other paired fields, such as a provenance field and the
  # field it documents.
  #
  # A $6 value has the form:
  #
  #   <tag>-<occurrence>[/<script>][/<direction>]
  #
  # * _tag_ — the tag of the field on the other end of the link. An 880
  #   field points at the original tag ("245" in "245-01"); every other
  #   field points at "880" ("880-02").
    # * _occurrence_ — a two-digit number (01-99) shared by the two
    #   members of a pair. It identifies which occurrence of the linked
    #   tag is meant, so a record with two 245 fields can each have their
    #   own 880.
  # * _script_ — an optional two-character MARC script identification
  #   code (for example "(3" for Arabic, "$1" for Chinese).
  # * _direction_ — an optional rendering direction, "/r" for
  #   right-to-left or "/r/" for a right-to-left field whose contents
  #   include left-to-right text. It is preserved verbatim.
  #
  # Note that the script code may itself contain characters that are not
  #   alphanumeric, so the string is split on "/" rather than parsed with
  #   a permissive regex.
  class FieldLink
    # Sentinel distinguishing "not supplied" from nil (script/direction removal).
    UNCHANGED = Object.new.freeze

    # Tag named by the link ("880" on an original field, the original
    # tag on an 880 field).
    attr_reader :tag

    # Two-digit occurrence number as an Integer (1..99).
    attr_reader :occurrence

    # Optional MARC script identification code, e.g. "$1".
    attr_reader :script

    # Optional direction information (nil, "/r" or "/r/"), verbatim.
    attr_reader :direction

    # Parse the value of a $6 subfield. Raises MARC::LinkException for
    # values that are not well formed.
    def self.parse(value)
      raise MARC::LinkException.new("invalid field link (nil)") if value.nil?

      head, *parts = value.split("/", -1)
      match = /\A([0-9A-Za-z]{3})-([0-9]{2})\z/.match(head.to_s)
      unless match
        raise MARC::LinkException.new(
          "invalid field link #{value.inspect}: expected '<tag>-<nn>'"
        )
      end

      script = parts.shift
      if script == "" && parts.empty? && value.end_with?("/")
        raise MARC::LinkException.new(
          "invalid field link #{value.inspect}: dangling '/'"
        )
      end
      unless script.nil? || script.empty? || script.length == 2
        raise MARC::LinkException.new(
          "invalid field link #{value.inspect}: script code must be two characters"
        )
      end

      direction =
        case parts
        in [] then nil
        in ["r"] then "/r"
        in ["r", ""] then "/r/"
        else
          raise MARC::LinkException.new(
            "invalid field link #{value.inspect}: direction must be /r or /r/"
          )
        end

      occurrence_number = Integer(match[2])
      unless (1..99).cover?(occurrence_number)
        raise MARC::LinkException.new(
          "invalid field link #{value.inspect}: occurrence must be 01-99"
        )
      end

      new(match[1], occurrence_number, script: (script if script && !script.empty?),
        direction: direction)
    end

    def initialize(tag, occurrence, script: nil, direction: nil)
      @tag = tag
      @occurrence = occurrence
      @script = script
      @direction = direction
      freeze
    end

    # Rebuild the canonical $6 subfield value.
    def to_s
      value = format("%s-%02d", @tag, @occurrence)
      value += "/#{@script}" if @script
      value + @direction.to_s
    end

    # The key shared by members of one relationship: the tag named by the
    # link together with the occurrence number. Two fields with the same
    # actual tag but different occurrences belong to different groups.
    def key
      [@tag, @occurrence]
    end

    # Return an equivalent link with selected parts replaced. Pass nil
    # for +script+ or +direction+ to drop that part.
    def with(tag: UNCHANGED, occurrence: UNCHANGED, script: UNCHANGED, direction: UNCHANGED)
      self.class.new(
        tag == UNCHANGED ? @tag : tag,
        occurrence == UNCHANGED ? @occurrence : occurrence,
        script: script == UNCHANGED ? @script : script,
        direction: direction == UNCHANGED ? @direction : direction
      )
    end

    def ==(other)
      other.is_a?(self.class) &&
        tag == other.tag && occurrence == other.occurrence &&
        script == other.script && direction == other.direction
    end

    alias eql? ==

    def hash
      [tag, occurrence, script, direction].hash
    end

  end

  class DataField
    # Return the first MARC::FieldLink parsed from the field's $6
    # subfields, or nil when the field has no $6.
    def link
      sub = find { |s| s.code == "6" }
      sub && MARC::FieldLink.parse(sub.value)
    end

    # Like #link but returns nil instead of raising for malformed $6.
    def link?
      link
    rescue MARC::LinkException
      nil
    end

    # Replace the field's $6 value. By default the $6 keeps its
    # position among the subfields; pass move_to_front: true to place
    # it first, as MARC conventions expect for newly linked fields.
    def set_link(link_value, move_to_front: false)
      value = link_value.is_a?(MARC::FieldLink) ? link_value.to_s : link_value
      index = subfields.index { |s| s.code == "6" }
      if index
        subfields[index] = MARC::Subfield.new("6", value)
        if move_to_front && index.nonzero?
          subfields.unshift(subfields.delete_at(index))
        end
      else
        sf = MARC::Subfield.new("6", value)
        move_to_front ? subfields.unshift(sf) : subfields.push(sf)
      end
      value
    end

    # Remove every $6 subfield and return the field.
    def remove_link!
      subfields.reject! { |s| s.code == "6" }
      self
    end
  end
end
