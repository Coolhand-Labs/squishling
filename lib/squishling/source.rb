# frozen_string_literal: true

module Squishling
  # Ruby source for append_to_purpose items: a class or module body, or a single method, rendered as a
  # fenced code block. Parsed with Prism (a default gem since Ruby 3.3), loaded the first time it's needed.
  module Source
    # owner => { method name, or nil for the module itself => rendered source }. Weak keys, so classes replaced
    # by code reloading (e.g. Rails in development) can be collected.
    CACHE = ObjectSpace::WeakKeyMap.new
    CACHE_LOCK = Mutex.new
    CLASS_NODES = %i[class_node module_node].freeze

    class << self
      def render(item)
        # Methods are keyed by owner and name: `method(:call)` builds a new object on every call.
        owner, name = item.is_a?(Module) ? [item, nil] : [item.owner, item.name]
        CACHE_LOCK.synchronize do
          rendered = (CACHE[owner] ||= {})
          rendered.fetch(name) { rendered[name] = fence(*extract(item)) }
        end
      end

      private

      def extract(item)
        require "prism"
        item.is_a?(Module) ? module_source(item) : method_source(unwrap(item))
      end

      def module_source(mod)
        constant = constant_location(mod)
        sources = constant ? class_bodies(mod, constant) : method_defs(mod)
        raise ConfigurationError, "append_to_purpose: source for #{mod.inspect} isn't available" if sources.empty?

        [display_name(mod), sources.join("\n\n")]
      end

      # Every `class X`/`module X` body for the constant that holds one of its methods, so a class reopened across
      # files is covered, or the Class.new/Module.new block the constant is assigned from (`X = Class.new do`).
      def class_bodies(mod, constant)
        anchors = [constant, *own_methods(mod).map { |method| location(method) }].compact
        anchors.group_by(&:first).flat_map do |file, pairs|
          tree, text = parse(file)
          nodes = pairs.map(&:last).uniq.filter_map do |line|
            innermost(tree, line) { |node, enclosing| defines?(node, enclosing, mod, [file, line] == constant) }
          end
          nodes.uniq.sort_by { |node| node.location.start_line }.map { |node| slice(node, text) }
        end
      end

      # Without a constant there's no class body to find reliably (its methods may come from a factory or a
      # class_eval inside unrelated code), so each of its own `def`s is sent instead, and nothing around them.
      def method_defs(mod)
        parsed = {}
        own_methods(mod).sort_by { |method| location(method) || [] }.filter_map { |method| def_source(method, parsed) }
      end

      def method_source(method)
        label = method_label(method)
        source = def_source(method)
        raise ConfigurationError, "append_to_purpose: source for #{label} isn't available" unless source

        [label, source]
      end

      # The method's own `def`, matched by name and line, or nil (define_method, attr_*, eval'd code).
      def def_source(method, parsed = {})
        file, line = location(method)
        return unless file

        tree, text = (parsed[file] ||= parse(file))
        node = innermost(tree, line) do |candidate|
          candidate.type == :def_node && candidate.name == method.original_name && candidate.location.start_line == line
        end
        node && slice(node, text)
      end

      # [file, line] for code in a readable file. Some Ruby builds add columns to source_location.
      def location(method)
        file, line = method.source_location
        [file, line] if file && File.file?(file)
      end

      # A squished method resolves to Squishling's wrapper; show the implementation beneath it.
      def unwrap(method)
        Wrapper.implementation(method) or
          raise ConfigurationError, "append_to_purpose: #{method.name} has no implementation to show"
      end

      # Named after the def that's shown, so an alias is labeled by its original name.
      def method_label(method)
        owner = method.owner
        return "#{display_name(owner.attached_object)}.#{method.original_name}" if owner.singleton_class?

        "#{display_name(owner)}##{method.original_name}"
      end

      # The module's own instance and singleton methods, as UnboundMethods.
      def own_methods(mod)
        names = mod.instance_methods(false) + mod.private_instance_methods(false)
        singleton = mod.singleton_class
        singleton_names = mod.singleton_methods(false) + singleton.private_instance_methods(false)
        names.filter_map { |name| own_method(mod, name) } +
          singleton_names.filter_map { |name| own_method(singleton, name) }
      end

      # instance_method resolves to a prepended module (Squishling's wrapper, or any other) first. Going through
      # instance_method also bypasses a class's own `self.method` (e.g. an HTTP request model).
      def own_method(mod, name)
        method = mod.instance_method(name)
        method = method.super_method until method.nil? || method.owner == mod
        method
      end

      # A `class X`/`module X` node whose full lexical name is the module's (so a monkeypatch from inside an
      # unrelated `Vendor::Client` never sends that class for `Billing::Client`), or the Class.new/Module.new block
      # at the constant's assignment, never an unrelated block that happens to define one of its methods.
      def defines?(node, enclosing, mod, at_constant)
        if CLASS_NODES.include?(node.type)
          lexical_name([*enclosing, node]) == module_name(mod)
        else
          at_constant && node.type == :call_node && node.name == :new && node.block &&
            %w[Class Module].include?(node.receiver&.slice)
        end
      end

      # Where the module's constant is assigned, or nil when it has none in a readable file: anonymous, nested in
      # an anonymous namespace ("#<Module:0x...>::Parser"), given a temporary name (set_temporary_name), or eval'd.
      def constant_location(mod)
        name = module_name(mod)
        file, line = name && Object.const_source_location(name)
        [file, line] if file && File.file?(file)
      rescue NameError
        nil
      end

      # The deepest node containing the line that satisfies the block, which also gets the enclosing nodes.
      def innermost(node, line, enclosing = [], &)
        location = node.location
        return nil unless line.between?(location.start_line, location.end_line)

        node.compact_child_nodes.each do |child|
          found = innermost(child, line, [*enclosing, node], &)
          return found if found
        end
        yield(node, enclosing) ? node : nil
      end

      # The constant a class/module node defines, from it and the class/module nodes around it
      # (`module Billing; class Client` and `class Billing::Client` are both "Billing::Client").
      def lexical_name(nodes)
        nodes.select { |node| CLASS_NODES.include?(node.type) }.reduce("") do |name, node|
          path = node.constant_path.slice
          next path.delete_prefix("::") if path.start_with?("::") || name.empty?

          "#{name}::#{path}"
        end
      end

      # Ruby reads source as UTF-8 whatever the locale (e.g. LANG=C in a container).
      def parse(file)
        text = File.read(file, encoding: Encoding::UTF_8).scrub
        [Prism.parse(text).value, text.lines]
      rescue SystemCallError => e
        raise ConfigurationError, "append_to_purpose: can't read #{file} (#{e.class})"
      end

      # Give the node's first line its source line's indentation (it may start mid-line, as in
      # `parser = Class.new do`), then strip the indentation shared by every line.
      def slice(node, text)
        lines = "#{text[node.location.start_line - 1][/\A */]}#{node.slice}".lines
        indent = lines.reject { |line| line.strip.empty? }.map { |line| line[/\A */].size }.min || 0
        lines.map { |line| line.strip.empty? ? "\n" : line[indent..] }.join.chomp
      end

      def display_name(mod)
        return "(#{mod.class} instance)" unless mod.is_a?(Module)

        module_name(mod) || "(anonymous #{mod.is_a?(Class) ? 'class' : 'module'})"
      end

      # The constant name Ruby assigned, ignoring any `def self.name` override on the class.
      def module_name(mod)
        Module.instance_method(:name).bind_call(mod)
      end

      # A fence longer than any backtick run in the source, so the code can't close it early.
      def fence(label, code)
        ticks = "`" * [3, (code.scan(/`+/).map(&:size).max || 0) + 1].max
        "#{ticks}ruby\n# Source: #{label}\n#{code}\n#{ticks}"
      end
    end
  end
end
