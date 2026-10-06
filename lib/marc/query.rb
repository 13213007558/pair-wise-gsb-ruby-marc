module MARC
  class Query
    FieldWitness = Struct.new(:field_index, :field, :subfield_witnesses) do
      def tag
        field.tag
      end

      def indicator1
        field.indicator1
      end

      def indicator2
        field.indicator2
      end

      def to_h
        {
          type: :field,
          field_index: field_index,
          tag: field.tag,
          indicator1: field.indicator1,
          indicator2: field.indicator2,
          subfield_positions: subfield_witnesses.map(&:subfield_index)
        }
      end
    end

    SubfieldWitness = Struct.new(:field_index, :subfield_index, :subfield) do
      def code
        subfield.code
      end

      def value
        subfield.value
      end

      def to_h
        {
          type: :subfield,
          field_index: field_index,
          subfield_index: subfield_index,
          code: subfield.code,
          value: subfield.value
        }
      end
    end

    CountWitness = Struct.new(:scope, :selector, :count, :witnesses) do
      def to_h
        {
          type: :count,
          scope: scope,
          selector: selector,
          count: count,
          witnesses: witnesses.map(&:to_h)
        }
      end
    end
    ValueRef = Struct.new(:name)
    FieldBinding = Struct.new(:field, :field_index)
    FieldContext = Struct.new(:field, :field_index)
    INTERNAL_FIELDS_KEY = :__marc_query_internal_fields__

    class Solution
      attr_reader :bindings, :witnesses

      def initialize(bindings = {}, witnesses = [])
        @bindings = bindings
        @witnesses = witnesses
      end

      def merge(other)
        Solution.new(bindings.merge(other.bindings), witnesses + other.witnesses)
      end
    end

    class Result
      attr_reader :solution

      def initialize(success, solution = nil)
        @success = success
        @solution = solution
      end

      def match?
        @success
      end

      def witnesses
        match? ? solution.witnesses : []
      end

      def field_witnesses
        flat_witnesses.grep(FieldWitness)
      end

      def subfield_witnesses
        flat_witnesses.grep(SubfieldWitness)
      end

      def positions
        field_positions = field_witnesses.map do |witness|
          { type: :field, field_index: witness.field_index, tag: witness.tag }
        end
        subfield_positions = subfield_witnesses.map(&:to_h)
        field_positions + subfield_positions
      end

      def to_h
        {
          match: match?,
          bindings: serialize_bindings(bindings),
          witnesses: witnesses.map(&:to_h)
        }
      end

      def bindings
        match? ? solution.bindings.dup : {}
      end

      def field(name)
        binding = bindings[name]
        binding.is_a?(FieldBinding) ? binding.field : nil
      end

      def field_index(name)
        binding = bindings[name]
        binding.is_a?(FieldBinding) ? binding.field_index : nil
      end

      def value(name)
        bindings[name]
      end

      private

      def flat_witnesses
        witnesses.each_with_object([]) do |witness, result|
          result.concat(witness.witnesses) if witness.is_a?(CountWitness)
          if witness.is_a?(FieldWitness)
            result << witness
            result.concat(witness.subfield_witnesses)
          else
            result << witness unless witness.is_a?(CountWitness)
          end
        end
      end

      def serialize_bindings(bindings)
        bindings.each_with_object({}) do |(name, value), result|
          next if name == INTERNAL_FIELDS_KEY
          result[name] = value.is_a?(FieldBinding) ? value.field_index : value
        end
      end
    end

    class Evaluation
      attr_reader :record

      def initialize(record)
        @record = record
      end

      def success(bindings = {}, witnesses = [])
        [:ok, Solution.new(bindings, witnesses)]
      end

      def failure
        [:no, nil]
      end

      def ok?(result)
        result.first == :ok
      end

      def solution(result)
        result.last
      end

      def data_fields
        record.fields.each_with_index.select { |field, _| field.is_a?(MARC::DataField) }
      end

      def fields_matching(selector)
        return data_fields if selector.nil?
        data_fields.select { |field, _| tag_matches?(selector, field.tag) }
      end

      def tag_matches?(selector, tag)
        case selector
        when Array then selector.any? { |item| tag_matches?(item, tag) }
        when Range then selector.cover?(tag)
        when Regexp then !!(tag =~ selector)
        else tag == selector
        end
      end

      def field_link(field)
        link = field["8"]
        link ? link.to_s.split(/[-\/\\]/).first : nil
      end

      def subfield_positions(field, selector = nil)
        field.subfields.each_with_index.select do |subfield, index|
          selector.nil? || selector == index || code_matches?(selector, subfield.code)
        end
      end

      def match_value?(expected, actual)
        case expected
        when Regexp then actual.is_a?(String) && !!(actual =~ expected)
        when Array then expected.include?(actual)
        when Range then expected.cover?(actual)
        when Proc then expected.call(actual)
        else actual == expected
        end
      end

      def count_matches?(expected, count)
        case expected
        when Range then expected.cover?(count)
        when Hash
          minimum = expected[:min] || expected[:gte] || 0
          maximum = expected[:max] || expected[:lte]
          count >= minimum && (maximum.nil? || count <= maximum)
        when Proc then expected.call(count)
        else count == expected
        end
      end

      def resolve(value, bindings)
        case value
        when ValueRef
          bindings[value.name]
        else
          value
        end
      end
    end

    module Node
    end

    class AndNode
      include Node

      def initialize(children)
        @children = children
      end

      def evaluate(evaluation, field_context, candidates, bindings)
        solution = Solution.new(bindings.dup, [])
        @children.each do |child|
          result = child.evaluate(evaluation, field_context, candidates, solution.bindings)
          return evaluation.failure unless evaluation.ok?(result)
          solution = solution.merge(evaluation.solution(result))
        end
        evaluation.success(solution.bindings, solution.witnesses)
      end
    end

    class OrNode
      include Node

      def initialize(children)
        @children = children
      end

      def evaluate(evaluation, field_context, candidates, bindings)
        @children.each do |child|
          result = child.evaluate(evaluation, field_context, candidates, bindings)
          return result if evaluation.ok?(result)
        end
        evaluation.failure
      end
    end

    class NotNode
      include Node

      def initialize(child)
        @child = child
      end

      def evaluate(evaluation, field_context, candidates, bindings)
        result = @child.evaluate(evaluation, field_context, candidates, bindings)
        evaluation.ok?(result) ? evaluation.failure : evaluation.success(bindings.dup, [])
      end
    end

    class FieldNode
      include Node

      def initialize(selector, condition = nil, options = {})
        @selector = selector
        @condition = condition
        @as = options[:as]
        @link = options[:link]
        @different_from = options.fetch(:different_from, true)
        @internal_name = "__marc_query_field_#{object_id}__".to_sym
        @bound_internal_names = []
      end

      def evaluate(evaluation, field_context, _candidates, bindings)
        @bound_internal_names = bindings[INTERNAL_FIELDS_KEY] || []
        evaluation.fields_matching(@selector).each do |field, field_index|
          next if bound_to_different_occurrence?(field_index, bindings)
          candidate_bindings = bindings.dup
          link_key = evaluation.field_link(field)

          if @link
            expected = @link.is_a?(ValueRef) ? evaluation.resolve(@link, candidate_bindings) : @link
            next if link_key.nil? || (!expected.nil? && link_key != expected)
            candidate_bindings[@link.name] = link_key if @link.is_a?(ValueRef)
          end

          field_binding = FieldBinding.new(field, field_index)
          candidate_bindings[@internal_name] = field_binding
          candidate_bindings[INTERNAL_FIELDS_KEY] =
            @bound_internal_names + [@internal_name]
          candidate_bindings[@as] = field_binding if @as
          result = evaluate_condition(evaluation, field, field_index, candidate_bindings)
          next unless evaluation.ok?(result)

          matched = evaluation.solution(result)
          subfield_witnesses = matched.witnesses.grep(SubfieldWitness).uniq
          subfield_witnesses = subfield_witnesses.sort_by(&:subfield_index)
          add_link_witness(field, field_index, subfield_witnesses) if @link
          witnesses = [FieldWitness.new(field_index, field, subfield_witnesses)]
          witnesses.concat(matched.witnesses.grep(CountWitness))
          return evaluation.success(matched.bindings, witnesses)
        end
        evaluation.failure
      end

      private

      def bound_to_different_occurrence?(field_index, bindings)
        bindings.any? do |name, binding|
          next false if @bound_internal_names.include?(name) ||
            name == @internal_name || !binding.is_a?(FieldBinding)
          if @different_from == true
            binding.field_index == field_index
          else
            Array(@different_from).include?(name) && binding.field_index == field_index
          end
        end
      end

      def evaluate_condition(evaluation, field, field_index, bindings)
        return evaluation.success(bindings, []) unless @condition
        context = FieldContext.new(field, field_index)
        @condition.evaluate(evaluation, context, evaluation.subfield_positions(field), bindings)
      end

      def add_link_witness(field, field_index, witnesses)
        index = field.subfields.index { |subfield| subfield.code == "8" }
        return unless index
        witnesses.unshift(SubfieldWitness.new(field_index, index, field.subfields[index]))
      end
    end

    class LinkedFieldCondition
      include Node

      def initialize(name)
        @name = name
      end

      def evaluate(evaluation, context, _candidates, bindings)
        target = bindings[@name]
        return evaluation.failure unless target.is_a?(FieldBinding)
        return evaluation.failure if target.field_index == context.field_index
        source_link = evaluation.field_link(context.field)
        target_link = evaluation.field_link(target.field)
        return evaluation.failure if source_link.nil? || source_link != target_link
        evaluation.success(bindings.dup, [])
      end

    end

    class FieldAttributeCondition
      include Node

      def initialize(kind, expected, options = {})
        @kind = kind
        @expected = expected
        @as = options[:as]
      end

      def evaluate(evaluation, context, _candidates, bindings)
        actual = case @kind
        when :tag then context.field.tag
        when :indicator1 then context.field.indicator1
        when :indicator2 then context.field.indicator2
        when :field_link then evaluation.field_link(context.field)
        end
        expected = evaluation.resolve(@expected, bindings)
        return evaluation.failure unless evaluation.match_value?(expected, actual)
        updated = bindings.dup
        updated[@as] = actual if @as
        evaluation.success(updated, [])
      end
    end

    class SubfieldCondition
      include Node

      def initialize(selector, expected = true, options = {})
        @selector = selector
        @expected = expected
        @as = options[:as]
      end

      def evaluate(evaluation, context, candidates, bindings)
        candidates.each do |subfield, index|
          next unless position_matches?(index, subfield)
          expected = evaluation.resolve(@expected, bindings)
          next unless @expected == true || evaluation.match_value?(expected, subfield.value)
          updated = bindings.dup
          updated[@as] = subfield.value if @as
          witness = SubfieldWitness.new(context.field_index, index, subfield)
          return evaluation.success(updated, [witness])
        end
        evaluation.failure
      end

      private

      def position_matches?(index, subfield)
        return true if @selector.nil? || @selector == index
        case @selector
        when Array then @selector.include?(subfield.code)
        when Regexp then !!(subfield.code =~ @selector)
        else subfield.code == @selector
        end
      end
    end

    class CountFieldsNode
      include Node

      def initialize(selector, condition, expected)
        @selector = selector
        @condition = condition
        @expected = expected
      end

      def evaluate(evaluation, _field_context, _candidates, bindings)
        witnesses = []
        evaluation.fields_matching(@selector).each do |field, field_index|
          context = FieldContext.new(field, field_index)
          if @condition.nil?
            witnesses << FieldWitness.new(field_index, field, [])
            next
          end
          result = @condition.evaluate(
            evaluation, context, evaluation.subfield_positions(field), bindings
          )
          next unless evaluation.ok?(result)
          solution = evaluation.solution(result)
          subfields = solution.witnesses.grep(SubfieldWitness)
          witnesses << FieldWitness.new(field_index, field, subfields)
        end
        return evaluation.failure unless evaluation.count_matches?(@expected, witnesses.length)
        witness = CountWitness.new(:field, @selector, witnesses.length, witnesses)
        evaluation.success(bindings.dup, [witness])
      end
    end

    class CountSubfieldsNode
      include Node

      def initialize(selector, expected, count_expected)
        @selector = selector
        @expected = expected
        @count_expected = count_expected
      end

      def evaluate(evaluation, context, candidates, bindings)
        condition = SubfieldCondition.new(@selector, @expected)
        witnesses = candidates.map do |subfield, index|
          result = condition.evaluate(evaluation, context, [[subfield, index]], bindings)
          evaluation.ok?(result) ? evaluation.solution(result).witnesses.grep(SubfieldWitness) : nil
        end.flatten.compact
        unless evaluation.count_matches?(@count_expected, witnesses.length)
          return evaluation.failure
        end
        witness = CountWitness.new(:subfield, @selector, witnesses.length, witnesses)
        evaluation.success(bindings.dup, [witness])
      end
    end

    module BuilderMethods
      def all(child = nil, &block)
        register(group_node(child || build_children(block), AndNode))
      end
      alias_method :and, :all

      def any(child = nil, &block)
        register(group_node(child || build_children(block), OrNode))
      end
      alias_method :or, :any

      def not(child = nil, &block)
        register(NotNode.new(child || build_children(block)))
      end
      alias_method :not_, :not
      alias_method :negate, :not

      private

      def build_children(block)
        builder = child_builder
        builder.instance_eval(&block)
        builder.to_node
      end

      def group_node(node, type)
        node.is_a?(type) ? node : type.new([node])
      end

      def child_builder
        self.class.new
      end

      def register(node)
        add(node)
      end
    end

    class RootBuilder
      include BuilderMethods

      def initialize
        @nodes = []
      end

      def field(selector, as: nil, link: nil, different_from: true, &block)
        condition = build_field_conditions(block) if block
        link = ValueRef.new(link) if link.is_a?(Symbol)
        node = FieldNode.new(
          selector, condition, as: as, link: link, different_from: different_from
        )
        @nodes << node
        node
      end
      alias_method :where, :field
      alias_method :has_field, :field

      def count_fields(tag, expected = nil, min: 1, max: nil, &block)
        expected ||= count_expected(min, max)
        condition = build_field_conditions(block) if block
        node = CountFieldsNode.new(tag, condition, expected)
        @nodes << node
        node
      end

      def bind(name)
        ValueRef.new(name)
      end

      def to_node
        @nodes.length == 1 ? @nodes.first : AndNode.new(@nodes)
      end

      def build_field_conditions(block)
        builder = FieldBuilder.new
        builder.instance_eval(&block)
        builder.to_node
      end

      def count_expected(minimum, maximum)
        minimum ||= 0
        maximum ? minimum..maximum : {min: minimum}
      end

      def add(node)
        @nodes << node
        node
      end
    end

    class FieldBuilder
      include BuilderMethods

      def initialize
        @nodes = []
      end

      def tag(value, as: nil)
        add(FieldAttributeCondition.new(:tag, value, as: as))
      end

      def indicator(value, as: nil)
        indicator1(value, as: as)
      end

      def indicator1(value, as: nil)
        add(FieldAttributeCondition.new(:indicator1, value, as: as))
      end

      def indicator2(value, as: nil)
        add(FieldAttributeCondition.new(:indicator2, value, as: as))
      end

      def field_link(value = true, as: nil)
        add(FieldAttributeCondition.new(:field_link, value, as: as))
      end
      alias_method :link8, :field_link

      def linked_to(name)
        add(LinkedFieldCondition.new(name))
      end

      def bind(name)
        ValueRef.new(name)
      end

      def subfield(code, value = true, as: nil)
        add(SubfieldCondition.new(code, value, as: as))
      end

      def count_subfields(code, expected = nil, min: 1, max: nil, value: true)
        expected ||= count_expected(min, max)
        add(CountSubfieldsNode.new(code, value, expected))
      end

      def to_node
        @nodes.length == 1 ? @nodes.first : AndNode.new(@nodes)
      end

      def add(node)
        @nodes << node
        node
      end

      def count_expected(minimum, maximum)
        minimum ||= 0
        maximum ? minimum..maximum : {min: minimum}
      end
    end

    def self.build(&block)
      builder = RootBuilder.new
      builder.instance_eval(&block)
      new(builder.to_node)
    end

    def self.match?(record, &block)
      build(&block).match?(record)
    end

    def self.match(record, &block)
      build(&block).match(record)
    end

    def initialize(node)
      @node = node
    end

    def match?(record)
      match(record).match?
    end

    def match(record)
      evaluation = Evaluation.new(record)
      result = @node.evaluate(evaluation, nil, nil, {})
      if evaluation.ok?(result)
        Result.new(true, evaluation.solution(result))
      else
        Result.new(false)
      end
    end
  end
end
