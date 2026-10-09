# frozen_string_literal: true

module Squishling
  # append_instructions: extra system-prompt sections placed after the instructions, layered
  # class -> subclass -> method -> call. Each level adds to the levels above it; `false` drops them.
  module Appendices
    ITEM_TYPES = [String, Module, Method, UnboundMethod, Proc].freeze

    module_function

    # Validates one level's items. A single item or an Array; `false` (alone or as an element) is kept as a
    # marker that clears everything declared before it.
    def normalize(items, label)
      items = [items] unless items.is_a?(Array)
      items.each { |item| check!(item, label) unless item == false }
      items.dup.freeze
    end

    # The items in effect once every level is concatenated in order.
    def resolve(items)
      items.reduce([]) { |kept, item| item == false ? [] : kept << item }
    end

    # Strings verbatim, classes/modules/methods as their source, procs evaluated against the receiver
    # (returning any of those, an Array of them, or nil/false to add nothing, so `-> { strict? && "..." }` works).
    def render(items, receiver, label)
      items.flat_map do |item|
        next [render_item(item)] unless item.is_a?(Proc)

        values = receiver.instance_exec(&item)
        (values.is_a?(Array) ? values : [values]).select(&:itself).map do |value|
          check!(value, "#{label} append_instructions proc", procs: false)
          render_item(value)
        end
      end
    end

    def render_item(item)
      item.is_a?(String) ? item : Source.render(item)
    end

    def check!(item, label, procs: true)
      allowed = procs ? ITEM_TYPES : ITEM_TYPES - [Proc]
      return if allowed.any? { |type| item.is_a?(type) }

      raise ConfigurationError, "#{label}: append_instructions items must be Strings, classes or modules, " \
                                "#{procs ? 'methods, or procs' : 'or methods'} (got #{describe(item)})"
    end

    # Simple values as written; anything else by class only, since a proc returning the wrong object (a user,
    # a config) shouldn't copy its attributes into an error message.
    def describe(item)
      case item
      when Symbol, Numeric, true, nil then item.inspect
      else "an instance of #{item.class}"
      end
    end
  end
end
