# frozen_string_literal: true

module Squishling
  # The requests for one squished method, made through the adapter each step names (see Adapter; the default one
  # when it names none). Squishling owns the conversation: each Conversation holds the system prompt, the output
  # schema, and the messages so far, and every request sends all of it to the adapter.
  class LLMClient
    # One chat on one escalation step. messages are { role:, content: } Hashes, grown by #ask. files go with the
    # chat's first message.
    Conversation = Struct.new(:step, :instructions, :schema, :messages, :files)

    # Where a response came from: the request that got it (see Observer::Call#request_id) and the model that answered.
    Origin = Data.define(:request_id, :model)

    # purpose, harness (the harness type), handed_off (squish! sent the call here), and apprentice (an apprentice's
    # shadow run) are only told to the observer. call_id names the call; each request gets its own id under it (see
    # Observer::Call). budget (see Budget) caps the tokens the requests of this client may use between them.
    def initialize(label, purpose:, harness:, handed_off:, budget: {}, call_id: nil, apprentice: false)
      @label = label
      @purpose = purpose
      @harness = harness
      @handed_off = handed_off
      @call_id = call_id
      @apprentice = apprentice
      @requests = 0
      @request_ids = {}.compare_by_identity
      @requests_lock = Mutex.new
      @config = Squishling.config
      @adapters = {}
      @adapters_lock = Mutex.new
      @tally = Budget::Tally.new(budget, cache_reads: @config.budget_counts_cache_reads)
    end

    # Raises ConfigurationError if any of the steps names an adapter that isn't configured, or (given images) names one
    # that doesn't take them, so a mistake ends the call before it has made a request.
    def check_adapters!(steps, files = [])
      steps.each do |step|
        adapter_for(step)
        check_files!(step, files)
      end
    end

    # The budget limit this client's requests have reached ({ limit:, max:, used: }), or nil. Checked before each
    # request, so one already in flight is never cut short.
    def exhausted_budget
      @tally.exhausted
    end

    # Runs each job on its own thread and returns, in order, each job's [value, exception]. steps are the
    # escalation steps the jobs ask on, in the same order. Only provider requests run here: parsing, validation, and
    # the developer's callbacks stay on the caller's thread. Fiber storage is inherited by the threads, and each
    # job's adapter carries over whatever request context it keeps (see Adapter::Base#capture_context). If the
    # caller is interrupted while waiting (a timeout, Thread#raise), the requests still running are stopped rather
    # than left running unobserved.
    def concurrently(jobs, steps)
      return jobs.map { |job| capture(job) } if jobs.size < 2

      adapters = steps.map { |step| adapter_for(step) }
      contexts = captured_contexts(adapters)
      threads = jobs.zip(adapters).map do |job, adapter|
        thread = Thread.new { with_context(adapter, contexts.fetch(adapter)) { capture(job) } }
        thread.report_on_exception = false
        thread
      end
      threads.map(&:value)
    ensure
      threads&.each { |thread| thread.kill.join if thread.alive? }
    end

    # A fresh conversation on one escalation step, with the system prompt, the strict output schema, and the files
    # (Images and Documents) its first message carries. Raises ConfigurationError for files when the step's adapter
    # doesn't take them.
    def chat(step, instructions:, schema:, files: [])
      check_files!(step, files)
      Conversation.new(step, instructions, schema, [], files)
    end

    # One request in the conversation: the message goes in, and the adapter's answer is kept in it so the next
    # message continues from there. A request that fails leaves the conversation as it was.
    # The adapter raises ConfigurationError for setup mistakes (never retried) and LLMError for failures worth another
    # attempt, which moves on to the next attempt of the escalation (or propagates from the last one).
    # The request runs inside the configured observer (see Observer), on this thread: for samples, the worker's.
    # role is nil for an escalation attempt, :sample (with its name) or :judge; attempt counts in attempts.
    # reask is whether this message is a retry in the same chat (see ModelPath::Step#request_params).
    def ask(chat, message, step, attempt:, attempts:, role: nil, sample: nil, reask: false)
      call = call_info(step, :chat, role:, sample:, attempt:, attempts:)
      response = Observer.around(call) { complete(chat, message, step, reask) }
      @requests_lock.synchronize { @request_ids[response] = call.request_id }
      response
    end

    # The Origin of a response #ask returned.
    def origin_of(response)
      request_id = @requests_lock.synchronize { @request_ids[response] }
      Origin.new(request_id:, model: Observer.usage(response).model)
    end

    # Whether the step's adapter can make System One judgments (judges with type: :judgment).
    def judgments?(step)
      adapter = adapter_for(step)
      adapter.respond_to?(:judgments?) && adapter.respond_to?(:judge) && adapter.judgments?
    end

    # A System One judgment on one step, through the step's adapter.
    # Judge#check_judgments! has already refused an adapter that can't.
    def judge(input, questions:, step:)
      @tally.add(adapter_for(step).judge(input, questions:, step:, label: @label))
    end

    # #judge inside the configured observer (see Observer), attempt counting in attempts.
    def observed_judgment(input, questions:, step:, attempt:, attempts:)
      call = call_info(step, :judgment, role: :judge, attempt:, attempts:)
      Observer.around(call) { judge(input, questions:, step:) }
    end

    private

    def check_files!(step, files)
      return if files.empty?

      adapter = adapter_for(step)
      accepted = accepted_media_types(adapter, step)
      raise ConfigurationError, no_files_message(adapter, step, files) if accepted.empty?

      missing = files.reject { |file| accepted?(file, accepted) }.map { |file| file.media_type || "an image URL" }.uniq
      return if missing.empty?

      raise ConfigurationError, "#{@label}: the call has #{missing.join(', ')} files, but the " \
                                "#{adapter.class} adapter takes #{accepted.join(', ')} (see Adapter::Base#media_types)"
    end

    # An image given by URL has no type of its own, so an adapter that takes any image takes it.
    def accepted?(file, accepted)
      file.media_type ? accepted.include?(file.media_type) : accepted.any? { |type| type.start_with?("image/") }
    end

    # An adapter written before media_types is asked images? instead (and takes no documents).
    def accepted_media_types(adapter, step)
      return adapter.media_types(step) if adapter.respond_to?(:media_types)

      adapter.respond_to?(:images?) && adapter.images? ? Image::MEDIA_TYPES.keys : []
    end

    def no_files_message(adapter, step, files)
      model = step.model ? " for #{step.model}" : ""
      kind = files.all?(Image) ? "images" : "files"
      "#{@label}: the call has #{kind}, but the #{adapter.class} adapter doesn't take them#{model} " \
        "(see Adapter::Base#media_types)"
    end

    # The step's adapter, looked up once per call: the adapter a job's context was captured from is the one that
    # makes its request, even if the configuration changes meanwhile.
    def adapter_for(step)
      @adapters_lock.synchronize { @adapters[step.adapter] ||= @config.adapter_for(step.adapter) }
    end

    def capture(job)
      [job.call, nil]
    rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised on the caller's thread
      [nil, e]
    end

    def complete(chat, message, step, reask)
      messages = chat.messages + [{ role: :user, content: content(chat, message) }]
      request = Adapter::Request.new(label: @label, model: step.model, provider: step.provider,
        instructions: chat.instructions, messages:, schema: chat.schema, params: step.request_params(reask),
        cache: step.cache, adapter: step.adapter)
      adapter = adapter_for(step)
      response = adapter.complete(request)
      unless response.is_a?(Adapter::Response)
        raise ConfigurationError, "#{@label}: the #{adapter.class} adapter must return a " \
                                  "Squishling::Adapter::Response from #complete, got #{response.class}"
      end

      chat.messages = messages + [{ role: :assistant, content: response.text }]
      @tally.add(response)
    end

    # Each distinct adapter's request context, taken once on the caller's thread.
    def captured_contexts(adapters)
      adapters.each_with_object({}.compare_by_identity) do |adapter, contexts|
        contexts[adapter] = capture_context(adapter) unless contexts.key?(adapter)
      end
    end

    def capture_context(adapter)
      adapter.capture_context if adapter.respond_to?(:capture_context)
    end

    # A chat's first message carries its files, after the text, as content parts (see Adapter::Request); every other
    # message is the text alone.
    def content(chat, message)
      return message unless chat.messages.empty? && chat.files&.any?

      [{ type: :text, text: message }, *chat.files.map { |file| file_part(file) }]
    end

    def file_part(file)
      file.is_a?(Image) ? { type: :image, image: file } : { type: :file, file: }
    end

    def with_context(adapter, context, &)
      return yield unless adapter.respond_to?(:with_context)

      adapter.with_context(context, &)
    end

    def call_info(step, request, attempt:, attempts:, role: nil, sample: nil)
      Observer::Call.new(label: @label, purpose: @purpose, harness: @harness, handed_off: @handed_off, role:, sample:,
        attempt:, attempts:, model: step.model, provider: step.provider, adapter: step.adapter, request:,
        call_id: @call_id, request_id: next_request_id, apprentice: @apprentice)
    end

    # "<call_id>.<n>", numbered in the order requests start (samples start theirs on worker threads).
    def next_request_id
      return unless @call_id

      "#{@call_id}.#{@requests_lock.synchronize { @requests += 1 }}"
    end
  end
end
