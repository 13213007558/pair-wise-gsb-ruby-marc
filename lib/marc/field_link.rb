module MARC
  # A value object representing the contents of subfield $6.
  #
  # The syntax is +<tag>-<occurrence>[/<script>][/<orientation>]+. The tag on
  # a regular field is 880. The tag on an 880 field is the original field's
  # tag. Occurrence numbers are two digits and connect the two fields.
  #
  # The optional script value is an opaque script identification code. The
  # optional orientation +r+ marks a right-to-left field; omission means the
  # default left-to-right orientation.
  class FieldLink
    PATTERN = /\A([0-9A-Za-z]{3})-(\d{2})(?:\/(.+))?\z/

    attr_reader :tag, :occurrence, :script

    def self.parse(value)
      return nil unless value.is_a?(String)

      match = PATTERN.match(value.strip)
      return nil unless match

      suffix = match[3]
      script = nil
      right_to_left = false

      if suffix
        parts = suffix.split("/", -1)
        return nil unless parts.length == 1 || parts.length == 2
        return nil if parts.length == 2 && parts[1] != "r"
        return nil if parts.length == 1 && parts[0].empty?
        right_to_left = parts.last == "r"
        script = right_to_left && parts.length == 2 ? parts[0] : parts[0]
        script = nil if right_to_left && parts.length == 1
      end

      number = Integer(match[2])
      return nil if number < 1 || number > 99

      new(match[1].upcase, format_occurrence(number), script, right_to_left)
    end

    def self.format_occurrence(number)
      format("%02d", Integer(number))
    end

    def initialize(tag, occurrence, script = nil, right_to_left = false)
      @tag = tag.to_s.upcase
      unless @tag.match(/\A[0-9A-Za-z]{3}\z/)
        raise MARC::Exception, "link tag must be three letters or numbers"
      end
      number = Integer(occurrence.to_s)
      raise MARC::Exception, "link occurrence must be between 1 and 99" unless number.between?(1, 99)

      @occurrence = self.class.format_occurrence(number)
      @script = script.nil? || script.to_s.empty? ? nil : script.to_s
      if @script && (@script.include?("/") || @script == "r")
        raise MARC::Exception, "invalid link script #{@script.inspect}"
      end
      @right_to_left = right_to_left ? true : false
    end

    def right_to_left?
      @right_to_left
    end
    alias_method :rtl?, :right_to_left?

    def with(tag: @tag, occurrence: @occurrence, script: @script, right_to_left: @right_to_left)
      self.class.new(tag, occurrence, script, right_to_left)
    end

    def to_s
      value = "#{@tag}-#{@occurrence}"
      value += "/#{@script}" if @script
      value += "/r" if @right_to_left
      value
    end

    def ==(other)
      other.is_a?(self.class) &&
        tag == other.tag &&
        occurrence == other.occurrence &&
        script == other.script &&
        right_to_left? == other.right_to_left?
    end
    alias_method :eql?, :==

    def hash
      [tag, occurrence, script, right_to_left?].hash
    end
  end
end
